"""
Qualys qscanner CLI Integration
Executes qscanner to scan container images deployed to ACI/ACA
"""
import os
import json
import subprocess
import logging
import tempfile
from typing import Dict, Optional
from datetime import datetime


class QScanner:
    """
    Client for Qualys qscanner CLI tool
    Scans Docker images using qscanner --image flag
    """

    def __init__(self, qscanner_path: str = '/usr/local/bin/qscanner',
                 qualys_username: Optional[str] = None,
                 qualys_password: Optional[str] = None):
        """
        Initialize qscanner client

        Args:
            qscanner_path: Path to qscanner binary
            qualys_username: Qualys credentials for qscanner authentication
            qualys_password: Qualys password
        """
        self.qscanner_path = qscanner_path
        self.username = qualys_username or os.environ.get('QUALYS_USERNAME')
        self.password = qualys_password or os.environ.get('QUALYS_PASSWORD')
        self.timeout = int(os.environ.get('SCAN_TIMEOUT', '1800'))

        # Verify qscanner is available
        if not os.path.exists(qscanner_path):
            logging.warning(f'qscanner not found at {qscanner_path}, will attempt to use from PATH')
            self.qscanner_path = 'qscanner'

    def scan_image(self, registry: str, repository: str, tag: str = 'latest',
                   digest: Optional[str] = None, custom_tags: Optional[Dict] = None) -> Dict:
        """
        Scan a container image using qscanner

        Args:
            registry: Container registry (e.g., docker.io, mcr.microsoft.com, myacr.azurecr.io)
            repository: Image repository (e.g., library/nginx, myapp/backend)
            tag: Image tag (default: latest)
            digest: Optional image digest for pinned versions
            custom_tags: Optional custom tags to apply to scan (for tracking)

        Returns:
            Dictionary containing scan results
        """
        # Construct image identifier
        image_id = f'{registry}/{repository}:{tag}'
        if digest:
            image_id = f'{registry}/{repository}@{digest}'

        logging.info(f'Scanning image with qscanner: {image_id}')

        try:
            # Build qscanner command
            cmd = self._build_scan_command(image_id, custom_tags)

            # Execute qscanner
            result = self._execute_qscanner(cmd)

            # Parse qscanner output
            scan_results = self._parse_qscanner_output(result)

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
                    'scanner': 'qscanner',
                    'raw_output': scan_results
                }
            }

        except subprocess.TimeoutExpired:
            logging.error(f'qscanner timed out after {self.timeout} seconds scanning {image_id}')
            raise Exception(f'Scan timeout for image {image_id}')
        except Exception as e:
            logging.error(f'Error scanning image {image_id}: {str(e)}')
            raise

    def _build_scan_command(self, image_id: str, custom_tags: Optional[Dict] = None) -> list:
        """
        Build qscanner command with appropriate flags

        Args:
            image_id: Full image identifier
            custom_tags: Optional tags for scan tracking

        Returns:
            Command as list of arguments
        """
        cmd = [
            self.qscanner_path,
            '--image', image_id,
            '--output-format', 'json',
            '--output-file', '-',  # Output to stdout
        ]

        # Add authentication if provided
        if self.username and self.password:
            cmd.extend(['--username', self.username])
            cmd.extend(['--password', self.password])

        # Add custom tags for tracking
        if custom_tags:
            for key, value in custom_tags.items():
                cmd.extend(['--tag', f'{key}={value}'])

        # Add image name as tag for correlation
        cmd.extend(['--tag', f'image={image_id}'])

        # Add timestamp tag
        cmd.extend(['--tag', f'scan_time={datetime.utcnow().isoformat()}'])

        # Additional qscanner options from environment
        severity_threshold = os.environ.get('SEVERITY_THRESHOLD', 'MEDIUM')
        cmd.extend(['--severity-threshold', severity_threshold])

        logging.info(f'qscanner command: {" ".join([c if c != self.password else "***" for c in cmd])}')

        return cmd

    def _execute_qscanner(self, cmd: list) -> str:
        """
        Execute qscanner command and return output

        Args:
            cmd: Command to execute

        Returns:
            Command output (JSON string)
        """
        try:
            logging.info('Executing qscanner...')

            # Create environment with credentials
            env = os.environ.copy()
            if self.username:
                env['QUALYS_USERNAME'] = self.username
            if self.password:
                env['QUALYS_PASSWORD'] = self.password

            # Execute qscanner
            process = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=self.timeout,
                env=env,
                check=False  # Don't raise on non-zero exit
            )

            # Check for errors
            if process.returncode != 0:
                error_msg = process.stderr or process.stdout
                logging.error(f'qscanner failed with exit code {process.returncode}: {error_msg}')

                # qscanner may return non-zero even on successful scans with findings
                # Try to parse output anyway
                if process.stdout and process.stdout.strip().startswith('{'):
                    logging.warning('qscanner returned non-zero but has JSON output, continuing...')
                    return process.stdout
                else:
                    raise Exception(f'qscanner failed: {error_msg}')

            logging.info('qscanner completed successfully')
            return process.stdout

        except subprocess.TimeoutExpired as e:
            logging.error(f'qscanner timed out after {self.timeout} seconds')
            raise
        except Exception as e:
            logging.error(f'Error executing qscanner: {str(e)}')
            raise

    def _parse_qscanner_output(self, output: str) -> Dict:
        """
        Parse qscanner JSON output

        Args:
            output: qscanner stdout (JSON)

        Returns:
            Parsed scan results
        """
        try:
            # qscanner outputs JSON
            data = json.loads(output)
            logging.info('Successfully parsed qscanner JSON output')
            return data

        except json.JSONDecodeError as e:
            logging.error(f'Failed to parse qscanner output as JSON: {str(e)}')
            logging.debug(f'Output was: {output[:500]}...')

            # Return minimal structure if parsing fails
            return {
                'status': 'PARSE_ERROR',
                'raw_output': output,
                'error': str(e)
            }

    def _parse_vulnerabilities(self, scan_results: Dict) -> Dict:
        """
        Parse vulnerability information from qscanner results

        Args:
            scan_results: Parsed qscanner output

        Returns:
            Dictionary with vulnerability counts by severity
        """
        vuln_summary = {
            'CRITICAL': 0,
            'HIGH': 0,
            'MEDIUM': 0,
            'LOW': 0,
            'INFORMATIONAL': 0,
            'total': 0,
            'details': []
        }

        # qscanner JSON structure varies, try common paths
        vulnerabilities = []

        # Try different possible paths in qscanner output
        if 'vulnerabilities' in scan_results:
            vulnerabilities = scan_results['vulnerabilities']
        elif 'results' in scan_results and 'vulnerabilities' in scan_results['results']:
            vulnerabilities = scan_results['results']['vulnerabilities']
        elif 'imageDetails' in scan_results:
            vulnerabilities = scan_results.get('imageDetails', {}).get('vulnerabilities', [])

        for vuln in vulnerabilities:
            # Parse severity (handle different formats)
            severity = self._normalize_severity(vuln.get('severity', 'UNKNOWN'))

            if severity in vuln_summary:
                vuln_summary[severity] += 1

            vuln_summary['total'] += 1

            # Store vulnerability details
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
                    f'Critical={vuln_summary["CRITICAL"]}, High={vuln_summary["HIGH"]}, '
                    f'Medium={vuln_summary["MEDIUM"]}, Low={vuln_summary["LOW"]}')

        return vuln_summary

    def _parse_compliance(self, scan_results: Dict) -> Dict:
        """
        Parse compliance information from qscanner results

        Args:
            scan_results: Parsed qscanner output

        Returns:
            Dictionary with compliance status
        """
        compliance = {
            'passed': 0,
            'failed': 0,
            'total': 0,
            'checks': []
        }

        # Extract compliance data if available
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
        """
        Normalize severity levels to standard values

        Args:
            severity: Severity string from qscanner

        Returns:
            Normalized severity (CRITICAL, HIGH, MEDIUM, LOW, INFORMATIONAL)
        """
        severity = str(severity).upper()

        # Handle numeric severities (1-5 scale)
        severity_map = {
            '5': 'CRITICAL',
            '4': 'HIGH',
            '3': 'MEDIUM',
            '2': 'LOW',
            '1': 'INFORMATIONAL'
        }

        if severity in severity_map:
            return severity_map[severity]

        # Handle text severities with variations
        if 'CRIT' in severity:
            return 'CRITICAL'
        elif 'HIGH' in severity or 'URGENT' in severity:
            return 'HIGH'
        elif 'MED' in severity or 'MODERATE' in severity:
            return 'MEDIUM'
        elif 'LOW' in severity or 'MINOR' in severity:
            return 'LOW'
        elif 'INFO' in severity:
            return 'INFORMATIONAL'

        return 'MEDIUM'  # Default

    def get_qscanner_version(self) -> str:
        """
        Get qscanner version

        Returns:
            Version string
        """
        try:
            result = subprocess.run(
                [self.qscanner_path, '--version'],
                capture_output=True,
                text=True,
                timeout=10
            )
            return result.stdout.strip()
        except Exception as e:
            logging.error(f'Error getting qscanner version: {str(e)}')
            return 'unknown'
