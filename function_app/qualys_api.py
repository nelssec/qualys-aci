import json
import logging
import urllib.parse
import requests
from datetime import datetime, timezone
from typing import Dict, Optional

logger = logging.getLogger(__name__)
API_TIMEOUT = 30


def get_headers(token: str) -> Dict:
    return {
        'Authorization': f'Bearer {token}',
        'Content-Type': 'application/json',
        'Accept': 'application/json'
    }


def get_acr_connector(gateway_url: str, token: str, connector_name: str = None,
                      application_id: str = None) -> Optional[Dict]:
    url = f"{gateway_url}/csapi/v1.3/registry/acr/connectors"
    headers = get_headers(token)

    response = requests.get(url, headers=headers, timeout=API_TIMEOUT)

    if response.status_code != 200:
        logger.warning(f"Failed to list ACR connectors: {response.status_code}")
        return None

    connectors = response.json()
    if not connectors:
        return None

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
    url = f"{gateway_url}/csapi/v1.3/registry/acr/connector"
    headers = get_headers(token)

    payload = {
        "name": name,
        "applicationId": application_id,
        "clientSecret": client_secret,
        "description": description or f"ACR connector created {datetime.now(timezone.utc).strftime('%Y-%m-%d')}"
    }

    logger.info(f"Creating ACR connector: {name}")
    response = requests.post(url, json=payload, headers=headers, timeout=API_TIMEOUT)

    if response.status_code in [200, 201]:
        logger.info(f"Created ACR connector: {name}")
        try:
            return {'created': True, 'connector': response.json() if response.text else {}, 'name': name}
        except json.JSONDecodeError:
            return {'created': True, 'name': name}
    else:
        logger.error(f"Failed to create ACR connector: {response.status_code} - {response.text[:200]}")
        return {'created': False, 'error': response.text[:200], 'status_code': response.status_code}


def ensure_acr_connector(gateway_url: str, token: str, name: str,
                         application_id: str, client_secret: str) -> Dict:
    existing = get_acr_connector(gateway_url, token, connector_name=name)
    if existing:
        logger.info(f"Found existing ACR connector: {name}")
        return {
            'connector_name': existing.get('name'),
            'connector_id': existing.get('acrConnectorId') or existing.get('connectorId'),
            'created': False
        }

    existing = get_acr_connector(gateway_url, token, application_id=application_id)
    if existing:
        logger.info(f"Found existing ACR connector by app ID: {existing.get('name')}")
        return {
            'connector_name': existing.get('name'),
            'connector_id': existing.get('acrConnectorId') or existing.get('connectorId'),
            'created': False
        }

    result = create_acr_connector(gateway_url, token, name, application_id, client_secret)
    if result.get('created'):
        return {
            'connector_name': name,
            'connector_id': result.get('connector', {}).get('acrConnectorId') or result.get('connector', {}).get('connectorId'),
            'created': True
        }
    return {'connector_name': None, 'error': result.get('error')}


def get_registry_uuid(gateway_url: str, token: str, registry_uri: str) -> Optional[str]:
    url = f"{gateway_url}/csapi/v1.3/registry"
    headers = get_headers(token)
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
                        acr_login_server: str, connector_id: str) -> Dict:
    url = f"{gateway_url}/csapi/v1.3/registry"
    headers = get_headers(token)
    registry_uri = f"https://{acr_login_server}"

    payload = {
        "registryType": "Azure",
        "registryUri": registry_uri,
        "registryName": registry_name,
        "credentialType": "Azure",
        "registryUuid": None,
        "acrRequest": {"connectorId": connector_id}
    }

    logger.info(f"Creating ACR registry: {registry_name} -> {acr_login_server}")
    response = requests.post(url, json=payload, headers=headers, timeout=API_TIMEOUT)

    if response.status_code == 200:
        try:
            data = response.json()
            registry_uuid = data.get('registryUuid')
            if not registry_uuid:
                registry_uuid = get_registry_uuid(gateway_url, token, registry_uri)
            return {'created': True, 'registry_uuid': registry_uuid, 'registry_name': registry_name}
        except json.JSONDecodeError:
            registry_uuid = get_registry_uuid(gateway_url, token, registry_uri)
            return {'created': True, 'registry_uuid': registry_uuid, 'registry_name': registry_name}
    return {'created': False, 'error': response.text[:200], 'status_code': response.status_code}


def get_or_create_registry(gateway_url: str, token: str, registry_name: str,
                           acr_login_server: str, connector_name: str,
                           application_id: str = None, client_secret: str = None) -> Dict:
    registry_uri = f"https://{acr_login_server}"

    uuid = get_registry_uuid(gateway_url, token, registry_uri)
    if uuid:
        logger.info(f"Found existing registry: {uuid[:8]}...")
        return {'registry_uuid': uuid, 'created': False, 'exists': True}

    uuid = get_registry_by_name(gateway_url, token, registry_name)
    if uuid:
        logger.info(f"Found existing registry by name: {uuid[:8]}...")
        return {'registry_uuid': uuid, 'created': False, 'exists': True}

    connector_id = None
    if application_id and client_secret:
        logger.info(f"Ensuring ACR connector exists: {connector_name}")
        connector_result = ensure_acr_connector(gateway_url, token, connector_name, application_id, client_secret)
        if connector_result.get('error'):
            logger.warning(f"Connector issue: {connector_result.get('error')}")
        connector_id = connector_result.get('connector_id')

    if not connector_id:
        existing = get_acr_connector(gateway_url, token, connector_name=connector_name)
        if existing:
            connector_id = existing.get('acrConnectorId') or existing.get('connectorId')

    if not connector_id:
        return {'registry_uuid': None, 'created': False, 'exists': False, 'error': 'No connector ID available'}

    logger.info(f"Creating registry: {registry_name}")
    result = create_acr_registry(gateway_url, token, registry_name, acr_login_server, connector_id)

    if result.get('created'):
        return {'registry_uuid': result['registry_uuid'], 'created': True, 'exists': True}
    return {'registry_uuid': None, 'created': False, 'exists': False, 'error': result.get('error')}


def submit_on_demand_scan(gateway_url: str, token: str, registry_uuid: str,
                          repo_name: str, image_tag: str) -> Dict:
    url = f"{gateway_url}/csapi/v1.3/registry/{registry_uuid}/schedule"
    headers = get_headers(token)
    tag_filter = image_tag or 'latest'

    payload = {
        "filters": [{"repoTags": [{"repo": repo_name, "tag": tag_filter}], "days": None}],
        "name": f"Azure-{repo_name}-{tag_filter}-{datetime.now(timezone.utc).strftime('%Y%m%d%H%M%S')}",
        "onDemand": True,
        "schedule": "00:00",
        "forceScan": True,
        "registryType": "Azure"
    }

    logger.info(f"Submitting scan for {repo_name}:{tag_filter}")
    response = requests.post(url, json=payload, headers=headers, timeout=API_TIMEOUT)

    return {
        'status_code': response.status_code,
        'schedule_id': response.json().get('scheduleId') if response.ok else None,
        'schedule_name': payload['name'],
        'success': response.status_code in [200, 201, 202]
    }


def get_image_scan_status(gateway_url: str, token: str, image_id: str) -> Dict:
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

    return {'summary': summary, 'vulnerabilities': vulns[:20]}
