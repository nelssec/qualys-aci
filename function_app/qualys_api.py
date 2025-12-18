"""
Qualys Container Security API Client for Azure ACR

Registry-based scanning using Qualys Container Security API.
Uses Service Principal authentication for ACR access.
"""

import json
import logging
import urllib.parse
import requests
from datetime import datetime
from typing import Dict, Optional

logger = logging.getLogger(__name__)

API_TIMEOUT = 30


def get_headers(token: str) -> Dict:
    """Build headers for Qualys API requests."""
    return {
        'Authorization': f'Bearer {token}',
        'Content-Type': 'application/json',
        'Accept': 'application/json'
    }


def get_acr_connector(gateway_url: str, token: str, connector_name: str = None,
                      application_id: str = None) -> Optional[Dict]:
    """
    Get existing ACR connector by name or application ID.

    API: GET /csapi/v1.3/registry/acr/connectors
    """
    url = f"{gateway_url}/csapi/v1.3/registry/acr/connectors"
    headers = get_headers(token)

    response = requests.get(url, headers=headers, timeout=API_TIMEOUT)

    if response.status_code != 200:
        logger.warning(f"Failed to list ACR connectors: {response.status_code}")
        return None

    connectors = response.json()
    if not connectors:
        return None

    # Handle both list and dict responses
    if isinstance(connectors, dict):
        connectors = connectors.get('data', []) or [connectors]

    for connector in connectors:
        if connector_name and connector.get('name') == connector_name:
            return connector
        if application_id and connector.get('applicationId') == application_id:
            return connector

    return None


def create_acr_connector(gateway_url: str, token: str, name: str,
                         application_id: str, client_secret: str,
                         description: str = None) -> Dict:
    """
    Create ACR connector in Qualys.

    API: POST /csapi/v1.3/registry/acr/connector

    Args:
        gateway_url: Qualys gateway URL
        token: Qualys API token
        name: Connector name
        application_id: Azure Service Principal App ID (Client ID)
        client_secret: Azure Service Principal Secret
        description: Optional description

    Returns:
        Dict with connector details or error
    """
    url = f"{gateway_url}/csapi/v1.3/registry/acr/connector"
    headers = get_headers(token)

    payload = {
        "name": name,
        "applicationId": application_id,
        "clientSecret": client_secret,
        "description": description or f"ACR connector created {datetime.now().strftime('%Y-%m-%d')}"
    }

    logger.info(f"Creating ACR connector: {name}")
    response = requests.post(url, json=payload, headers=headers, timeout=API_TIMEOUT)

    if response.status_code in [200, 201]:
        logger.info(f"Created ACR connector: {name}")
        try:
            return {
                'created': True,
                'connector': response.json() if response.text else {},
                'name': name
            }
        except json.JSONDecodeError:
            return {'created': True, 'name': name}
    else:
        logger.error(f"Failed to create ACR connector: {response.status_code} - {response.text[:200]}")
        return {
            'created': False,
            'error': response.text[:200],
            'status_code': response.status_code
        }


def ensure_acr_connector(gateway_url: str, token: str, name: str,
                         application_id: str, client_secret: str) -> Dict:
    """
    Ensure ACR connector exists, creating if needed.

    Returns:
        Dict with connector info
    """
    # Check if connector exists
    existing = get_acr_connector(gateway_url, token, connector_name=name)
    if existing:
        logger.info(f"Found existing ACR connector: {name}")
        return {
            'connector_name': existing.get('name'),
            'connector_id': existing.get('connectorId'),
            'created': False
        }

    # Also check by application ID
    existing = get_acr_connector(gateway_url, token, application_id=application_id)
    if existing:
        logger.info(f"Found existing ACR connector by app ID: {existing.get('name')}")
        return {
            'connector_name': existing.get('name'),
            'connector_id': existing.get('connectorId'),
            'created': False
        }

    # Create new connector
    result = create_acr_connector(gateway_url, token, name, application_id, client_secret)
    if result.get('created'):
        return {
            'connector_name': name,
            'connector_id': result.get('connector', {}).get('connectorId'),
            'created': True
        }
    else:
        return {
            'connector_name': None,
            'error': result.get('error')
        }


def get_registry_uuid(gateway_url: str, token: str, registry_uri: str) -> Optional[str]:
    """Get registry UUID by ACR URI."""
    url = f"{gateway_url}/csapi/v1.3/registry"
    headers = get_headers(token)

    # Filter by registry URI
    filter_query = urllib.parse.quote(f'registryUri:"{registry_uri}"')
    params = {'filter': filter_query, 'pageNumber': 1, 'pageSize': 50}

    response = requests.get(url, headers=headers, params=params, timeout=API_TIMEOUT)

    if response.status_code == 204:
        return None

    if response.status_code != 200:
        logger.warning(f"Failed to query registries: {response.status_code}")
        return None

    data = response.json()
    if 'data' in data and data['data']:
        return data['data'][0].get('registryUuid')

    return None


def get_registry_by_name(gateway_url: str, token: str, registry_name: str) -> Optional[str]:
    """Get registry UUID by name."""
    url = f"{gateway_url}/csapi/v1.3/registry"
    headers = get_headers(token)
    params = {'pageNumber': 1, 'pageSize': 100}

    response = requests.get(url, headers=headers, params=params, timeout=API_TIMEOUT)
    if response.status_code != 200:
        return None

    data = response.json()
    for registry in data.get('data', []):
        if registry_name == registry.get('registryName'):
            return registry.get('registryUuid')

    return None


def create_acr_registry(gateway_url: str, token: str, registry_name: str,
                        acr_login_server: str, connector_name: str) -> Dict:
    """
    Create ACR registry in Qualys.

    API: POST /csapi/v1.3/registry

    Args:
        gateway_url: Qualys gateway URL
        token: Qualys API token
        registry_name: Name for the registry in Qualys
        acr_login_server: ACR login server (e.g., myacr.azurecr.io)
        connector_name: Name of the ACR connector to use

    Returns:
        Dict with registry UUID or error
    """
    url = f"{gateway_url}/csapi/v1.3/registry"
    headers = get_headers(token)

    # Registry URI format for ACR
    registry_uri = f"https://{acr_login_server}"

    payload = {
        "registryType": "ACR",
        "registryUri": registry_uri,
        "registryName": registry_name,
        "credentialType": "ACR",
        "acr": {
            "connectorName": connector_name
        }
    }

    logger.info(f"Creating ACR registry: {registry_name} -> {acr_login_server}")
    response = requests.post(url, json=payload, headers=headers, timeout=API_TIMEOUT)

    if response.status_code == 200:
        try:
            data = response.json()
            registry_uuid = data.get('registryUuid')
            if not registry_uuid:
                # Try to fetch it
                registry_uuid = get_registry_uuid(gateway_url, token, registry_uri)
            return {
                'created': True,
                'registry_uuid': registry_uuid,
                'registry_name': registry_name
            }
        except json.JSONDecodeError:
            registry_uuid = get_registry_uuid(gateway_url, token, registry_uri)
            return {
                'created': True,
                'registry_uuid': registry_uuid,
                'registry_name': registry_name
            }
    else:
        return {
            'created': False,
            'error': response.text[:200],
            'status_code': response.status_code
        }


def get_or_create_registry(gateway_url: str, token: str, registry_name: str,
                           acr_login_server: str, connector_name: str,
                           application_id: str = None, client_secret: str = None) -> Dict:
    """
    Get registry UUID, or create if it doesn't exist.

    This function:
    1. Checks if registry already exists
    2. If not, ensures ACR connector exists
    3. Creates the registry using the connector

    Args:
        gateway_url: Qualys gateway URL
        token: Qualys API token
        registry_name: Name for the registry in Qualys
        acr_login_server: ACR login server (e.g., myacr.azurecr.io)
        connector_name: Name of the ACR connector
        application_id: Service Principal App ID (for connector creation)
        client_secret: Service Principal Secret (for connector creation)

    Returns:
        Dict with registry_uuid or error
    """
    registry_uri = f"https://{acr_login_server}"

    # Check if registry already exists
    uuid = get_registry_uuid(gateway_url, token, registry_uri)
    if uuid:
        logger.info(f"Found existing registry: {uuid[:8]}...")
        return {'registry_uuid': uuid, 'created': False, 'exists': True}

    uuid = get_registry_by_name(gateway_url, token, registry_name)
    if uuid:
        logger.info(f"Found existing registry by name: {uuid[:8]}...")
        return {'registry_uuid': uuid, 'created': False, 'exists': True}

    # Ensure connector exists before creating registry
    if application_id and client_secret:
        logger.info(f"Ensuring ACR connector exists: {connector_name}")
        connector_result = ensure_acr_connector(
            gateway_url, token, connector_name, application_id, client_secret
        )
        if connector_result.get('error'):
            logger.warning(f"Connector issue: {connector_result.get('error')}")
            # Continue anyway - connector might exist with different name

    # Create the registry
    logger.info(f"Creating registry: {registry_name}")
    result = create_acr_registry(gateway_url, token, registry_name, acr_login_server, connector_name)

    if result.get('created'):
        return {
            'registry_uuid': result['registry_uuid'],
            'created': True,
            'exists': True
        }
    else:
        return {
            'registry_uuid': None,
            'created': False,
            'exists': False,
            'error': result.get('error')
        }


def submit_on_demand_scan(gateway_url: str, token: str, registry_uuid: str,
                          repo_name: str, image_tag: str) -> Dict:
    """
    Submit on-demand scan request to Qualys.

    API: POST /csapi/v1.3/registry/{registryUuid}/schedule
    """
    url = f"{gateway_url}/csapi/v1.3/registry/{registry_uuid}/schedule"
    headers = get_headers(token)

    tag_filter = image_tag if image_tag != 'latest' else '.*'

    payload = {
        "filters": [{
            "repoTags": [{
                "repo": repo_name,
                "tag": tag_filter
            }],
            "days": None
        }],
        "name": f"ACR-{repo_name}-{datetime.now().strftime('%Y%m%d%H%M%S')}",
        "onDemand": True,
        "schedule": "00:00",
        "forceScan": True,
        "registryType": "ACR"
    }

    logger.info(f"Submitting scan for {repo_name}:{image_tag}")
    response = requests.post(url, json=payload, headers=headers, timeout=API_TIMEOUT)

    return {
        'status_code': response.status_code,
        'schedule_id': response.json().get('scheduleId') if response.ok else None,
        'schedule_name': payload['name'],
        'success': response.status_code in [200, 201, 202]
    }


def get_image_scan_status(gateway_url: str, token: str, image_id: str) -> Dict:
    """
    Check scan status for an image.

    API: GET /csapi/v1.3/images/{imageSha}
    """
    encoded_id = urllib.parse.quote(image_id, safe='')
    url = f"{gateway_url}/csapi/v1.3/images/{encoded_id}"
    headers = get_headers(token)

    response = requests.get(url, headers=headers, timeout=API_TIMEOUT)

    if response.status_code == 404:
        return {'status': 'pending', 'found': False}

    if response.status_code != 200:
        return {'status': 'error', 'found': False, 'error': response.text[:100]}

    data = response.json()
    return {
        'status': 'complete' if data.get('scanStatus') == 'SUCCESS' else 'scanning',
        'found': True,
        'scan_status': data.get('scanStatus'),
        'vulnerabilities': data.get('vulnerabilities', {})
    }


def get_image_vulnerabilities(gateway_url: str, token: str, image_id: str) -> Dict:
    """
    Get vulnerability details for an image.

    API: GET /csapi/v1.3/images/{imageSha}/vuln
    """
    encoded_id = urllib.parse.quote(image_id, safe='')
    url = f"{gateway_url}/csapi/v1.3/images/{encoded_id}/vuln"
    headers = get_headers(token)
    params = {'pageNumber': 1, 'pageSize': 100}

    response = requests.get(url, headers=headers, params=params, timeout=API_TIMEOUT)

    if response.status_code != 200:
        return {
            'summary': {'total': 0, 'critical': 0, 'high': 0, 'medium': 0, 'low': 0},
            'vulnerabilities': [],
            'error': response.text[:100]
        }

    data = response.json()
    vulns = data.get('data', [])

    summary = {
        'total': len(vulns),
        'critical': sum(1 for v in vulns if v.get('severity') == 5),
        'high': sum(1 for v in vulns if v.get('severity') == 4),
        'medium': sum(1 for v in vulns if v.get('severity') == 3),
        'low': sum(1 for v in vulns if v.get('severity') in [1, 2])
    }

    return {
        'summary': summary,
        'vulnerabilities': vulns[:20]  # Return top 20 for notification
    }
