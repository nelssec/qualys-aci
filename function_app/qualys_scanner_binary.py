"""
Qualys qscanner integration using local binary
Runs qscanner binary directly in the function runtime
Auto-downloads latest qscanner binary on first use
"""
import os
import json
import logging
import subprocess
import urllib.request
from typing import Dict, Optional
from datetime import datetime
from pathlib import Path


class QScannerBinary:
    """
    Run qscanner scans using the local qscanner binary
    Much simpler and cheaper than spinning up ACI containers
    """

    def __init__(self, subscription_id: Optional[str] = None):
        """
        Initialize scanner with Qualys credentials

        Args:
            subscription_id: Optional subscription ID for tracking.
                           If not provided, uses AZURE_SUBSCRIPTION_ID env var.
        """
        self.subscription_id = subscription_id or os.environ.get('AZURE_SUBSCRIPTION_ID', 'unknown')

        # qscanner configuration
        self.qualys_pod = os.environ.get('QUALYS_POD')
        self.qualys_access_token = os.environ.get('QUALYS_ACCESS_TOKEN')
        self.scan_timeout = int(os.environ.get('SCAN_TIMEOUT', '1800'))

        # Find or download qscanner binary
        self.qscanner_path = self._find_qscanner_binary()
        logging.info(f'Using qscanner binary at: {self.qscanner_path}')

    def _find_qscanner_binary(self) -> Optional[str]:
        """
        Find or download qscanner binary

        Returns:
            Path to qscanner binary
        """
        # Persistent storage path (survives across function executions)
        persistent_path = '/home/qscanner'

        # Check if binary already exists
        if os.path.isfile(persistent_path) and os.access(persistent_path, os.X_OK):
            logging.info(f'Using existing qscanner binary at {persistent_path}')
            return persistent_path

        # Download binary
        logging.info('qscanner binary not found, downloading latest version...')
        return self._download_qscanner_binary(persistent_path)

    def _download_qscanner_binary(self, target_path: str) -> str:
        """
        Download qscanner binary from Qualys CDN

        Args:
            target_path: Where to save the binary

        Returns:
            Path to downloaded binary
        """
        version = os.environ.get('QSCANNER_VERSION', '4.6.0')
        download_url = f'https://cdn.qualys.com/qscanner/{version}/qscanner_{version}_linux_amd64'

        try:
            logging.info(f'Downloading qscanner v{version} from {download_url}')

            # Create parent directory if needed
            os.makedirs(os.path.dirname(target_path), exist_ok=True)

            # Download binary
            urllib.request.urlretrieve(download_url, target_path)

            # Make executable
            os.chmod(target_path, 0o755)

            # Verify
            if os.path.isfile(target_path) and os.access(target_path, os.X_OK):
                size = os.path.getsize(target_path)
                logging.info(f'Successfully downloaded qscanner binary ({size} bytes)')
                return target_path
            else:
                raise Exception('Downloaded binary is not executable')

        except Exception as e:
            logging.error(f'Failed to download qscanner binary: {str(e)}')
            raise Exception(f'Cannot download qscanner binary: {str(e)}. Please check QSCANNER_VERSION env var and network connectivity.')

    def scan_image(self, registry: str, repository: str, tag: str = 'latest',
                   digest: Optional[str] = None, custom_tags: Optional[Dict] = None) -> Dict:
        """
        Scan a container image using qscanner binary

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

        logging.info(f'Scanning image with qscanner binary: {image_id}')

        try:
            # Run qscanner and get output
            scan_output = self._run_qscanner(image_id, custom_tags)

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
                    'scanner': 'qscanner-binary',
                    'raw_output': scan_results
                }
            }

        except Exception as e:
            logging.error(f'Error scanning image {image_id}: {str(e)}')
            raise

    def _run_qscanner(self, image_id: str, custom_tags: Optional[Dict] = None) -> str:
        """
        Run qscanner binary as subprocess

        Args:
            image_id: Full image identifier to scan
            custom_tags: Optional tags for scan tracking

        Returns:
            qscanner output (JSON)
        """
        # Build command
        cmd = [
            self.qscanner_path,
            'image',
            image_id,
            '--pod', self.qualys_pod,
            '--scan-types', 'os,sca,secret',
            '--format', 'json',
            '--access-token', self.qualys_access_token,
            '--save',
            '--skip-verify-tls'
        ]

        # Add custom tags
        if custom_tags:
            for key, value in custom_tags.items():
                cmd.extend(['--tag', f'{key}={value}'])

        # Environment
        env = os.environ.copy()

        logging.info(f'Running: {" ".join(cmd[:4])}... (credentials hidden)')

        try:
            # Run qscanner
            result = subprocess.run(
                cmd,
                env=env,
                capture_output=True,
                text=True,
                timeout=self.scan_timeout,
                check=False  # Don't raise on non-zero exit (qscanner may exit 1 with findings)
            )

            # Log output
            if result.returncode not in [0, 1]:
                logging.error(f'qscanner exited with code {result.returncode}')
                logging.error(f'stderr: {result.stderr}')
                raise Exception(f'qscanner failed with exit code {result.returncode}')

            logging.info(f'qscanner completed with exit code {result.returncode}')

            # Return stdout (JSON output)
            return result.stdout

        except subprocess.TimeoutExpired:
            logging.error(f'qscanner timed out after {self.scan_timeout} seconds')
            raise TimeoutError(f'qscanner scan timed out after {self.scan_timeout} seconds')

        except Exception as e:
            logging.error(f'Error running qscanner: {str(e)}')
            raise

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
