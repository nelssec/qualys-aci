"""
Qualys Container Security API Integration
"""
import os
import json
import time
import logging
import requests
from typing import Dict, Optional
from requests.auth import HTTPBasicAuth


class QualysScanner:
    """
    Client for Qualys Container Security API
    Supports both cloud-based API and self-hosted scanner appliances
    """

    def __init__(self, api_url: str, username: str, password: str, scanner_id: Optional[str] = None):
        """
        Initialize Qualys scanner client

        Args:
            api_url: Qualys API endpoint (e.g., https://qualysapi.qualys.com)
            username: Qualys API username
            password: Qualys API password
            scanner_id: Optional scanner appliance ID for self-hosted scanners
        """
        self.api_url = api_url.rstrip('/')
        self.username = username
        self.password = password
        self.scanner_id = scanner_id
        self.session = requests.Session()
        self.session.auth = HTTPBasicAuth(username, password)
        self.session.headers.update({
            'Content-Type': 'application/json',
            'X-Requested-With': 'Python Qualys Scanner'
        })
        self.timeout = int(os.environ.get('SCAN_TIMEOUT', '1800'))

    def scan_image(self, registry: str, repository: str, tag: str = 'latest',
                   digest: Optional[str] = None) -> Dict:
        """
        Scan a container image using Qualys Container Security

        Args:
            registry: Container registry (e.g., docker.io, mcr.microsoft.com, myacr.azurecr.io)
            repository: Image repository (e.g., library/nginx, myapp/backend)
            tag: Image tag (default: latest)
            digest: Optional image digest for pinned versions

        Returns:
            Dictionary containing scan results
        """
        logging.info(f'Scanning image: {registry}/{repository}:{tag}')

        # Construct image identifier
        image_id = f'{registry}/{repository}:{tag}'
        if digest:
            image_id = f'{registry}/{repository}@{digest}'

        try:
            # Step 1: Submit scan request
            scan_id = self._submit_scan(image_id, registry, repository, tag)

            # Step 2: Poll for scan completion
            scan_status = self._wait_for_scan(scan_id)

            # Step 3: Retrieve detailed results
            scan_results = self._get_scan_results(scan_id)

            return {
                'scan_id': scan_id,
                'status': scan_status,
                'image': image_id,
                'vulnerabilities': self._parse_vulnerabilities(scan_results),
                'compliance': self._parse_compliance(scan_results),
                'metadata': {
                    'registry': registry,
                    'repository': repository,
                    'tag': tag,
                    'digest': digest,
                    'scan_timestamp': time.time()
                }
            }

        except Exception as e:
            logging.error(f'Error scanning image {image_id}: {str(e)}')
            raise

    def _submit_scan(self, image_id: str, registry: str, repository: str, tag: str) -> str:
        """
        Submit a scan request to Qualys

        Args:
            image_id: Full image identifier
            registry: Container registry
            repository: Image repository
            tag: Image tag

        Returns:
            Scan ID
        """
        endpoint = f'{self.api_url}/csapi/v1.3/images/scan'

        payload = {
            'imageId': image_id,
            'registry': registry,
            'repository': repository,
            'tag': tag
        }

        if self.scanner_id:
            payload['scannerId'] = self.scanner_id

        try:
            response = self.session.post(endpoint, json=payload, timeout=30)
            response.raise_for_status()

            result = response.json()
            scan_id = result.get('data', {}).get('scanId')

            if not scan_id:
                raise Exception(f'No scan ID returned from Qualys API: {result}')

            logging.info(f'Scan submitted successfully: {scan_id}')
            return scan_id

        except requests.exceptions.RequestException as e:
            logging.error(f'Error submitting scan: {str(e)}')
            raise

    def _wait_for_scan(self, scan_id: str, poll_interval: int = 10) -> str:
        """
        Wait for scan to complete

        Args:
            scan_id: Scan ID to monitor
            poll_interval: Seconds between status checks

        Returns:
            Final scan status
        """
        endpoint = f'{self.api_url}/csapi/v1.3/images/scan/{scan_id}/status'
        start_time = time.time()

        logging.info(f'Waiting for scan {scan_id} to complete...')

        while True:
            elapsed = time.time() - start_time
            if elapsed > self.timeout:
                raise TimeoutError(f'Scan {scan_id} timed out after {self.timeout} seconds')

            try:
                response = self.session.get(endpoint, timeout=30)
                response.raise_for_status()

                result = response.json()
                status = result.get('data', {}).get('status')

                logging.info(f'Scan {scan_id} status: {status}')

                if status in ['COMPLETED', 'SUCCESS']:
                    return 'COMPLETED'
                elif status in ['FAILED', 'ERROR']:
                    error_msg = result.get('data', {}).get('errorMessage', 'Unknown error')
                    raise Exception(f'Scan failed: {error_msg}')
                elif status in ['PENDING', 'RUNNING', 'IN_PROGRESS']:
                    time.sleep(poll_interval)
                else:
                    logging.warning(f'Unknown scan status: {status}')
                    time.sleep(poll_interval)

            except requests.exceptions.RequestException as e:
                logging.error(f'Error checking scan status: {str(e)}')
                time.sleep(poll_interval)

    def _get_scan_results(self, scan_id: str) -> Dict:
        """
        Retrieve detailed scan results

        Args:
            scan_id: Scan ID

        Returns:
            Complete scan results
        """
        endpoint = f'{self.api_url}/csapi/v1.3/images/scan/{scan_id}/results'

        try:
            response = self.session.get(endpoint, timeout=60)
            response.raise_for_status()

            result = response.json()
            return result.get('data', {})

        except requests.exceptions.RequestException as e:
            logging.error(f'Error retrieving scan results: {str(e)}')
            raise

    def _parse_vulnerabilities(self, scan_results: Dict) -> Dict:
        """
        Parse vulnerability information from scan results

        Args:
            scan_results: Raw scan results

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

        vulnerabilities = scan_results.get('vulnerabilities', [])

        for vuln in vulnerabilities:
            severity = vuln.get('severity', 'UNKNOWN').upper()
            if severity in vuln_summary:
                vuln_summary[severity] += 1

            vuln_summary['total'] += 1

            # Store vulnerability details
            vuln_summary['details'].append({
                'qid': vuln.get('qid'),
                'cve': vuln.get('cve'),
                'severity': severity,
                'title': vuln.get('title'),
                'package': vuln.get('software', {}).get('name'),
                'version': vuln.get('software', {}).get('version'),
                'fixed_version': vuln.get('software', {}).get('fixedVersion')
            })

        return vuln_summary

    def _parse_compliance(self, scan_results: Dict) -> Dict:
        """
        Parse compliance information from scan results

        Args:
            scan_results: Raw scan results

        Returns:
            Dictionary with compliance status
        """
        compliance = {
            'passed': 0,
            'failed': 0,
            'total': 0,
            'checks': []
        }

        compliance_checks = scan_results.get('compliance', [])

        for check in compliance_checks:
            status = check.get('status', 'UNKNOWN').upper()
            compliance['total'] += 1

            if status == 'PASS':
                compliance['passed'] += 1
            elif status == 'FAIL':
                compliance['failed'] += 1

            compliance['checks'].append({
                'id': check.get('id'),
                'title': check.get('title'),
                'status': status,
                'description': check.get('description')
            })

        return compliance

    def get_image_report(self, image_id: str) -> Dict:
        """
        Get existing scan report for an image

        Args:
            image_id: Image identifier

        Returns:
            Most recent scan report
        """
        endpoint = f'{self.api_url}/csapi/v1.3/images'

        params = {
            'filter': f'imageId:"{image_id}"',
            'pageSize': 1
        }

        try:
            response = self.session.get(endpoint, params=params, timeout=30)
            response.raise_for_status()

            result = response.json()
            images = result.get('data', [])

            if images:
                return images[0]

            return None

        except requests.exceptions.RequestException as e:
            logging.error(f'Error retrieving image report: {str(e)}')
            raise
