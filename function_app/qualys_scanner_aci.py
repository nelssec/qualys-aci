"""
Qualys qscanner integration using Azure Container Instances
Runs qscanner in a container on-demand for each scan
"""
import os
import json
import logging
import time
from typing import Dict, Optional
from datetime import datetime
from azure.mgmt.containerinstance import ContainerInstanceManagementClient
from azure.mgmt.containerinstance.models import (
    ContainerGroup, Container, ContainerGroupRestartPolicy,
    ResourceRequirements, ResourceRequests, EnvironmentVariable,
    OperatingSystemTypes, ImageRegistryCredential
)
from azure.mgmt.containerregistry import ContainerRegistryManagementClient
from azure.identity import DefaultAzureCredential
from azure.core.exceptions import HttpResponseError


class QScannerACI:
    """
    Run qscanner scans using Azure Container Instances
    Uses the official qualys/qscanner Docker image from Docker Hub
    """

    def __init__(self, subscription_id: Optional[str] = None):
        """
        Initialize ACI client with managed identity

        Args:
            subscription_id: Optional subscription ID for scan containers.
                           If not provided, uses AZURE_SUBSCRIPTION_ID env var.
                           This allows scanning across multiple subscriptions.
        """
        self.credential = DefaultAzureCredential()
        self.subscription_id = subscription_id or os.environ['AZURE_SUBSCRIPTION_ID']
        self.resource_group = os.environ.get('QSCANNER_RESOURCE_GROUP', 'qualys-scanner-rg')
        self.location = os.environ.get('AZURE_REGION', 'eastus')

        self.aci_client = ContainerInstanceManagementClient(
            credential=self.credential,
            subscription_id=self.subscription_id
        )

        # ACR client for fetching credentials
        self.acr_client = ContainerRegistryManagementClient(
            credential=self.credential,
            subscription_id=self.subscription_id
        )

        # qscanner configuration
        self.qscanner_image = os.environ.get('QSCANNER_IMAGE', 'qualys/qscanner:latest')
        self.qualys_pod = os.environ.get('QUALYS_POD')
        self.qualys_access_token = os.environ.get('QUALYS_ACCESS_TOKEN')
        self.scan_timeout = int(os.environ.get('SCAN_TIMEOUT', '1800'))

        # Parse ACR info from qscanner image if it's from ACR
        self.acr_server = None
        self.acr_name = None
        if '.azurecr.io' in self.qscanner_image:
            self.acr_server = self.qscanner_image.split('/')[0]
            self.acr_name = self.acr_server.split('.')[0]
            logging.info(f'QScanner image is from ACR: {self.acr_server}')

    def scan_image(self, registry: str, repository: str, tag: str = 'latest',
                   digest: Optional[str] = None, custom_tags: Optional[Dict] = None) -> Dict:
        """
        Scan a container image by creating an ACI container instance

        Args:
            registry: Container registry
            repository: Image repository
            tag: Image tag
            digest: Optional image digest
            custom_tags: Optional custom tags for tracking

        Returns:
            Dictionary containing scan results
        """
        # Construct image identifier
        image_id = f'{registry}/{repository}:{tag}'
        if digest:
            image_id = f'{registry}/{repository}@{digest}'

        logging.info(f'Scanning image with qscanner ACI: {image_id}')

        # Generate unique container group name
        container_name = self._generate_container_name(registry, repository, tag)

        try:
            # Create and run qscanner container
            scan_output = self._run_qscanner_container(image_id, container_name, custom_tags)

            # Parse results
            scan_results = self._parse_qscanner_output(scan_output)

            return {
                'scan_id': scan_results.get('scanId', datetime.utcnow().strftime('%Y%m%d%H%M%S')),
                'status': 'COMPLETED',
                'image': image_id,
                'vulnerabilities': self._parse_vulnerabilities(scan_results),
                'compliance': self._parse_compliance(scan_results),
                'metadata': {
                    'registry': registry,
                    'repository': repository,
                    'tag': tag,
                    'digest': digest,
                    'scan_timestamp': datetime.utcnow().isoformat(),
                    'scanner': 'qscanner-aci',
                    'container_name': container_name,
                    'raw_output': scan_results
                }
            }

        except Exception as e:
            logging.error(f'Error scanning image {image_id}: {str(e)}')
            raise
        finally:
            # Clean up: delete the container group
            try:
                self._delete_container_group(container_name)
            except Exception as e:
                logging.warning(f'Failed to delete container group {container_name}: {str(e)}')

    def _run_qscanner_container(self, image_id: str, container_name: str,
                                custom_tags: Optional[Dict] = None) -> str:
        """
        Create and run ACI container with qscanner

        Args:
            image_id: Full image identifier to scan
            container_name: Name for the ACI container group
            custom_tags: Optional tags for scan tracking

        Returns:
            Container logs (scan output)
        """
        logging.info(f'Creating ACI container group: {container_name}')

        # Build qscanner command
        command = self._build_qscanner_command(image_id, custom_tags)

        # Environment variables for qscanner
        env_vars = [
            EnvironmentVariable(name='QUALYS_ACCESS_TOKEN', secure_value=self.qualys_access_token),
        ]

        # Container configuration
        container = Container(
            name='qscanner',
            image=self.qscanner_image,
            resources=ResourceRequirements(
                requests=ResourceRequests(
                    memory_in_gb=4.0,  # QScanner minimum requirement
                    cpu=2.0             # QScanner minimum requirement
                )
            ),
            command=command,
            environment_variables=env_vars
        )

        # Get ACR credentials if qscanner image is from ACR
        acr_credentials = self._get_acr_credentials()
        image_registry_credentials = [acr_credentials] if acr_credentials else None

        # Container group configuration
        container_group = ContainerGroup(
            location=self.location,
            containers=[container],
            os_type=OperatingSystemTypes.linux,
            restart_policy=ContainerGroupRestartPolicy.never,  # Run once and stop
            image_registry_credentials=image_registry_credentials,  # ACR credentials
            tags={
                'purpose': 'qscanner',
                'image': image_id,
                'managed_by': 'qualys-aci-scanner'
            }
        )

        # Create the container group
        try:
            self.aci_client.container_groups.begin_create_or_update(
                resource_group_name=self.resource_group,
                container_group_name=container_name,
                container_group=container_group
            ).wait()

            logging.info(f'Container group {container_name} created')

        except HttpResponseError as e:
            logging.error(f'Failed to create container group: {str(e)}')
            raise

        # Wait for container to complete
        self._wait_for_container_completion(container_name)

        # Retrieve logs
        logs = self._get_container_logs(container_name)

        return logs

    def _wait_for_container_completion(self, container_name: str, poll_interval: int = 10):
        """
        Wait for container to complete execution

        Args:
            container_name: Container group name
            poll_interval: Seconds between status checks
        """
        start_time = time.time()
        logging.info(f'Waiting for container {container_name} to complete...')

        while True:
            elapsed = time.time() - start_time
            if elapsed > self.scan_timeout:
                raise TimeoutError(f'Container {container_name} timed out after {self.scan_timeout} seconds')

            try:
                container_group = self.aci_client.container_groups.get(
                    resource_group_name=self.resource_group,
                    container_group_name=container_name
                )

                # Check instance view for container state
                if container_group.instance_view and container_group.instance_view.state:
                    state = container_group.instance_view.state
                    logging.info(f'Container state: {state}')

                    if state in ['Succeeded', 'Failed', 'Terminated']:
                        # Check if qscanner container succeeded
                        if container_group.containers[0].instance_view:
                            container_state = container_group.containers[0].instance_view.current_state
                            if container_state.state == 'Terminated':
                                exit_code = container_state.exit_code
                                if exit_code == 0 or exit_code == 1:  # qscanner may exit 1 even on success with findings
                                    logging.info(f'Container completed with exit code: {exit_code}')
                                    return
                                else:
                                    raise Exception(f'qscanner failed with exit code {exit_code}')

                        return

                time.sleep(poll_interval)

            except HttpResponseError as e:
                logging.error(f'Error checking container status: {str(e)}')
                time.sleep(poll_interval)

    def _get_container_logs(self, container_name: str) -> str:
        """
        Retrieve container logs

        Args:
            container_name: Container group name

        Returns:
            Container logs
        """
        try:
            logs = self.aci_client.containers.list_logs(
                resource_group_name=self.resource_group,
                container_group_name=container_name,
                container_name='qscanner'
            )

            return logs.content or ''

        except HttpResponseError as e:
            logging.error(f'Failed to retrieve container logs: {str(e)}')
            return ''

    def _delete_container_group(self, container_name: str):
        """
        Delete the container group to clean up resources

        Args:
            container_name: Container group name
        """
        try:
            logging.info(f'Deleting container group: {container_name}')
            self.aci_client.container_groups.begin_delete(
                resource_group_name=self.resource_group,
                container_group_name=container_name
            ).wait()
            logging.info(f'Container group {container_name} deleted')

        except HttpResponseError as e:
            logging.warning(f'Failed to delete container group: {str(e)}')

    def _get_acr_credentials(self) -> Optional[ImageRegistryCredential]:
        """
        Get ACR credentials for pulling qscanner image

        Returns:
            ImageRegistryCredential if qscanner image is from ACR, None otherwise
        """
        if not self.acr_server or not self.acr_name:
            logging.info('QScanner image is not from ACR, no credentials needed')
            return None

        try:
            logging.info(f'Fetching ACR admin credentials for {self.acr_name}')

            # Ensure admin is enabled
            from azure.mgmt.containerregistry.models import RegistryUpdateParameters
            update_params = RegistryUpdateParameters(admin_user_enabled=True)
            self.acr_client.registries.begin_update(
                resource_group_name=self.resource_group,
                registry_name=self.acr_name,
                registry_update_parameters=update_params
            ).result()

            # Get admin credentials
            credentials = self.acr_client.registries.list_credentials(
                resource_group_name=self.resource_group,
                registry_name=self.acr_name
            )

            username = credentials.username
            password = credentials.passwords[0].value

            logging.info(f'Retrieved ACR credentials for {self.acr_server}')

            return ImageRegistryCredential(
                server=self.acr_server,
                username=username,
                password=password
            )

        except Exception as e:
            logging.error(f'Failed to get ACR credentials: {str(e)}')
            raise

    def _generate_container_name(self, registry: str, repository: str, tag: str) -> str:
        """
        Generate a unique container name

        Args:
            registry: Container registry
            repository: Image repository
            tag: Image tag

        Returns:
            Sanitized container name
        """
        # ACI names must be lowercase alphanumeric with hyphens
        timestamp = datetime.utcnow().strftime('%Y%m%d%H%M%S')
        base_name = f'qscanner-{repository.replace("/", "-")}-{tag}'.lower()

        # Remove invalid characters
        base_name = ''.join(c if c.isalnum() or c == '-' else '-' for c in base_name)

        # Limit length (max 63 characters)
        max_length = 50  # Leave room for timestamp
        if len(base_name) > max_length:
            base_name = base_name[:max_length]

        return f'{base_name}-{timestamp}'

    def _build_qscanner_command(self, image_id: str, custom_tags: Optional[Dict] = None) -> list:
        """
        Build qscanner command for container

        The qscanner binary is located at /opt/qualys/qscanner in the image.
        Based on: docker run --env QUALYS_ACCESS_TOKEN=$TOKEN qualys/qscanner:latest image image:tag --pod US2 --scan-types os,sca,secret --format json --skip-verify-tls

        Args:
            image_id: Full image identifier to scan (e.g., mcr.microsoft.com/image:tag)
            custom_tags: Optional tags for tracking

        Returns:
            Command as list for ACI container
        """
        cmd_parts = [
            '/opt/qualys/qscanner',  # qscanner binary location
            'image',              # qscanner subcommand
            image_id,             # Full image name with registry
            '--pod', self.qualys_pod,
            '--scan-types', 'os,sca,secret',  # Scan types: OS packages, SCA, secrets
            '--format', 'json',   # JSON output for parsing
            '--save',             # Save results to Qualys platform
            '--skip-verify-tls'   # Skip TLS verification for registries
        ]

        # Add custom tags for tracking
        if custom_tags:
            for key, value in custom_tags.items():
                cmd_parts.extend(['--tag', f'{key}={value}'])

        return cmd_parts

    def _parse_qscanner_output(self, output: str) -> Dict:
        """Parse qscanner JSON output"""
        try:
            # qscanner outputs JSON
            data = json.loads(output)
            logging.info('Successfully parsed qscanner JSON output')
            return data
        except json.JSONDecodeError as e:
            logging.error(f'Failed to parse qscanner output as JSON: {str(e)}')
            logging.debug(f'Output was: {output[:500]}...')
            return {
                'status': 'PARSE_ERROR',
                'raw_output': output,
                'error': str(e)
            }

    def _parse_vulnerabilities(self, scan_results: Dict) -> Dict:
        """Parse vulnerability information from qscanner results"""
        vuln_summary = {
            'CRITICAL': 0,
            'HIGH': 0,
            'MEDIUM': 0,
            'LOW': 0,
            'INFORMATIONAL': 0,
            'total': 0,
            'details': []
        }

        # Extract vulnerabilities from qscanner output
        vulnerabilities = []
        if 'vulnerabilities' in scan_results:
            vulnerabilities = scan_results['vulnerabilities']
        elif 'results' in scan_results and 'vulnerabilities' in scan_results['results']:
            vulnerabilities = scan_results['results']['vulnerabilities']

        for vuln in vulnerabilities:
            severity = self._normalize_severity(vuln.get('severity', 'UNKNOWN'))
            if severity in vuln_summary:
                vuln_summary[severity] += 1
            vuln_summary['total'] += 1

            vuln_summary['details'].append({
                'qid': vuln.get('qid') or vuln.get('id'),
                'cve': vuln.get('cve') or vuln.get('cveId'),
                'severity': severity,
                'title': vuln.get('title') or vuln.get('name'),
                'package': vuln.get('package', {}).get('name') if isinstance(vuln.get('package'), dict) else vuln.get('packageName'),
                'version': vuln.get('package', {}).get('version') if isinstance(vuln.get('package'), dict) else vuln.get('packageVersion'),
                'fixed_version': vuln.get('fixedVersion') or vuln.get('fix')
            })

        logging.info(f'Parsed {vuln_summary["total"]} vulnerabilities: '
                    f'Critical={vuln_summary["CRITICAL"]}, High={vuln_summary["HIGH"]}')

        return vuln_summary

    def _parse_compliance(self, scan_results: Dict) -> Dict:
        """Parse compliance information from qscanner results"""
        compliance = {
            'passed': 0,
            'failed': 0,
            'total': 0,
            'checks': []
        }

        compliance_checks = []
        if 'compliance' in scan_results:
            compliance_checks = scan_results['compliance']
        elif 'results' in scan_results and 'compliance' in scan_results['results']:
            compliance_checks = scan_results['results']['compliance']

        for check in compliance_checks:
            status = check.get('status', '').upper()
            compliance['total'] += 1

            if status in ['PASS', 'PASSED']:
                compliance['passed'] += 1
            elif status in ['FAIL', 'FAILED']:
                compliance['failed'] += 1

            compliance['checks'].append({
                'id': check.get('id') or check.get('checkId'),
                'title': check.get('title') or check.get('name'),
                'status': status,
                'description': check.get('description')
            })

        return compliance

    def _normalize_severity(self, severity: str) -> str:
        """Normalize severity levels"""
        severity = str(severity).upper()

        severity_map = {
            '5': 'CRITICAL',
            '4': 'HIGH',
            '3': 'MEDIUM',
            '2': 'LOW',
            '1': 'INFORMATIONAL'
        }

        if severity in severity_map:
            return severity_map[severity]

        if 'CRIT' in severity:
            return 'CRITICAL'
        elif 'HIGH' in severity:
            return 'HIGH'
        elif 'MED' in severity:
            return 'MEDIUM'
        elif 'LOW' in severity:
            return 'LOW'
        elif 'INFO' in severity:
            return 'INFORMATIONAL'

        return 'MEDIUM'
