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
import time
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
        # Check for bundled binary first (deployed with function app)
        bundled_path = os.path.join(os.path.dirname(__file__), 'qscanner')
        if os.path.isfile(bundled_path) and os.access(bundled_path, os.X_OK):
            logging.info(f'Using bundled qscanner binary at {bundled_path}')
            return bundled_path

        # Check for bundled tar.gz (for new deployments)
        version = os.environ.get('QSCANNER_VERSION', '4.6.0-4')
        bundled_targz = os.path.join(os.path.dirname(__file__), f'qscanner-{version}.linux-amd64.tar.gz')
        if os.path.isfile(bundled_targz):
            logging.info(f'Found bundled qscanner tar.gz at {bundled_targz}, extracting...')
            try:
                extracted_path = self._extract_bundled_targz(bundled_targz, bundled_path)
                if os.path.isfile(extracted_path) and os.access(extracted_path, os.X_OK):
                    logging.info(f'Successfully extracted bundled qscanner to {extracted_path}')
                    return extracted_path
            except Exception as e:
                logging.warning(f'Failed to extract bundled tar.gz: {str(e)}, will try other options')

        # Persistent storage path (survives across function executions)
        persistent_path = '/home/qscanner'

        # Check if binary already exists in persistent storage
        if os.path.isfile(persistent_path) and os.access(persistent_path, os.X_OK):
            logging.info(f'Using existing qscanner binary at {persistent_path}')
            return persistent_path

        # Download binary as last resort
        logging.info('qscanner binary not found, downloading latest version...')
        return self._download_qscanner_binary(persistent_path)

    def _download_qscanner_binary(self, target_path: str) -> str:
        """
        Download qscanner binary from Qualys CASK CDN

        Args:
            target_path: Where to save the binary

        Returns:
            Path to downloaded binary
        """
        version = os.environ.get('QSCANNER_VERSION', '4.6.0-4')
        download_url = f'https://cask.qg1.apps.qualys.com/cs/p/MwmsS_SfM0RTBIc5r-hpCUmY34xkB4n93rJNAfOf_BH5BnExjNT7P-48_03RUMr_/n/qualysincgov/b/us01-cask-artifacts/o/cs/qscanner/{version}/qscanner-{version}.linux-amd64.tar.gz'

        try:
            import tarfile
            import tempfile

            logging.info(f'Downloading qscanner v{version} from Qualys CASK')

            # Create parent directory if needed
            os.makedirs(os.path.dirname(target_path), exist_ok=True)

            # Download tar.gz to temp file
            temp_dir = tempfile.mkdtemp()
            tar_path = os.path.join(temp_dir, 'qscanner.tar.gz')

            logging.info(f'Downloading archive to {tar_path}')
            urllib.request.urlretrieve(download_url, tar_path)

            # Extract tar.gz
            logging.info('Extracting qscanner binary from archive')
            with tarfile.open(tar_path, 'r:gz') as tar:
                tar.extractall(temp_dir)

            # Move binary to target location
            binary_source = os.path.join(temp_dir, 'qscanner')
            if not os.path.isfile(binary_source):
                raise Exception(f'Binary not found in archive at {binary_source}')

            import shutil
            shutil.move(binary_source, target_path)

            # Make executable
            os.chmod(target_path, 0o755)

            # Clean up temp directory
            shutil.rmtree(temp_dir)

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

    def _extract_bundled_targz(self, targz_path: str, target_path: str) -> str:
        """
        Extract bundled qscanner tar.gz to target location

        Args:
            targz_path: Path to bundled tar.gz file
            target_path: Where to extract the binary

        Returns:
            Path to extracted binary
        """
        import tarfile
        import tempfile
        import shutil

        try:
            # Create temp directory for extraction
            temp_dir = tempfile.mkdtemp()

            logging.info(f'Extracting {targz_path} to temp directory')
            with tarfile.open(targz_path, 'r:gz') as tar:
                tar.extractall(temp_dir)

            # Find the binary in the extracted files
            binary_source = os.path.join(temp_dir, 'qscanner')
            if not os.path.isfile(binary_source):
                raise Exception(f'Binary not found in archive at {binary_source}')

            # Move to target location
            shutil.move(binary_source, target_path)

            # Make executable
            os.chmod(target_path, 0o755)

            # Clean up temp directory
            shutil.rmtree(temp_dir)

            logging.info(f'Extracted qscanner binary to {target_path}')
            return target_path

        except Exception as e:
            logging.error(f'Failed to extract bundled tar.gz: {str(e)}')
            raise

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
        Run qscanner binary as subprocess with remote registry scanning (Option 3)
        Includes retry logic with exponential backoff for transient failures

        Args:
            image_id: Full image identifier to scan (e.g., myacr.azurecr.io/image:tag)
            custom_tags: Optional tags for scan tracking

        Returns:
            qscanner output (JSON)
        """
        max_retries = 3
        base_delay = 2

        for attempt in range(max_retries + 1):
            try:
                return self._execute_qscanner(image_id, custom_tags, attempt)
            except Exception as e:
                is_last_attempt = attempt == max_retries
                is_retryable = self._is_retryable_error(e)

                if is_last_attempt or not is_retryable:
                    logging.error(f'qscanner failed after {attempt + 1} attempts')
                    raise

                delay = base_delay * (2 ** attempt)
                logging.warning(f'qscanner attempt {attempt + 1} failed with retryable error: {str(e)}')
                logging.info(f'Retrying in {delay} seconds...')
                time.sleep(delay)

        raise Exception('qscanner retry logic failed unexpectedly')

    def _is_retryable_error(self, error: Exception) -> bool:
        """Check if error is retryable (network issues, rate limits, etc.)"""
        error_str = str(error).lower()
        retryable_patterns = [
            'connection',
            'timeout',
            'network',
            'temporary',
            'rate limit',
            'too many requests',
            '429',
            '502',
            '503',
            '504'
        ]
        return any(pattern in error_str for pattern in retryable_patterns)

    def _execute_qscanner(self, image_id: str, custom_tags: Optional[Dict], attempt: int) -> str:
        """
        Execute qscanner binary for a single attempt

        Args:
            image_id: Full image identifier
            custom_tags: Optional tags
            attempt: Current attempt number (0-indexed)

        Returns:
            qscanner output (JSON)
        """
        # Build command for Option 3: Remote Images with ACR
        # Per Qualys ACR documentation: ./qscanner --pod US2 image <project>.azurecr.io/<image>:<tag>
        # The 'image' subcommand works for both local images (Option 1) and remote images (Option 3)
        # QScanner auto-detects it's a remote ACR URL and uses Azure SDK to authenticate via managed identity
        cmd = [
            self.qscanner_path,
            '--pod', self.qualys_pod,
            '--scan-types', 'os,sca,secret',
            '--format', 'json',
            '--access-token', self.qualys_access_token,
            '--save',
            '--skip-verify-tls',
            'image',  # Required per Qualys ACR docs
            image_id  # Image URL (e.g., myacr.azurecr.io/app:latest)
        ]

        # Add custom tags
        if custom_tags:
            for key, value in custom_tags.items():
                cmd.extend(['--tag', f'{key}={value}'])

        # Environment - Configure Azure SDK for ACR authentication
        # QScanner uses Azure SDK which automatically detects managed identity in Azure Functions
        # via MSI_ENDPOINT and MSI_SECRET environment variables (auto-provided by Azure)
        env = os.environ.copy()

        # For Azure ACR with system-assigned managed identity:
        # - MSI_ENDPOINT: Auto-provided by Azure Functions (enables managed identity)
        # - AZURE_TENANT_ID: The Azure AD tenant ID (configured in function app settings)
        # - QSCANNER_REGISTRY_USERNAME: MUST NOT be set (conflicts with Azure SDK auth)

        # Verify managed identity is available (Azure Functions provides MSI_ENDPOINT)
        if 'MSI_ENDPOINT' in env:
            if attempt == 0:
                logging.info(f'Using Azure system-assigned managed identity for ACR authentication')
                logging.info(f'  MSI Endpoint: {env["MSI_ENDPOINT"][:50]}...')
                logging.info(f'  Tenant ID: {env.get("AZURE_TENANT_ID", "not set")}')

            # Ensure QSCANNER_REGISTRY_USERNAME is NOT set (critical for Azure SDK auth)
            if 'QSCANNER_REGISTRY_USERNAME' in env:
                logging.warning('Removing QSCANNER_REGISTRY_USERNAME (conflicts with Azure SDK)')
                del env['QSCANNER_REGISTRY_USERNAME']
        else:
            logging.warning('MSI_ENDPOINT not found - not running in Azure Functions or managed identity not enabled')
            logging.warning('ACR authentication may fail for private registries')

        if attempt == 0:
            logging.info(f'Running remote registry scan: {image_id}')
            logging.info(f'Command: qscanner --pod {self.qualys_pod} ... {image_id}')
        else:
            logging.info(f'Retry attempt {attempt + 1}: {image_id}')

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
            logging.info(f'qscanner completed with exit code {result.returncode}')

            # Log stdout and stderr for debugging
            if result.stdout:
                logging.info(f'qscanner stdout (first 500 chars): {result.stdout[:500]}')
            if result.stderr:
                logging.warning(f'qscanner stderr: {result.stderr}')

            # Exit codes 0 and 1 are acceptable (1 = vulnerabilities found)
            if result.returncode not in [0, 1]:
                error_msg = f'qscanner failed with exit code {result.returncode}'
                if result.stderr:
                    error_msg += f': {result.stderr}'
                logging.error(error_msg)
                raise Exception(error_msg)

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
