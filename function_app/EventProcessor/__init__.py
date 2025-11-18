import os
import json
import logging
import azure.functions as func
from datetime import datetime

# Import helper modules from parent directory
import sys
from pathlib import Path
sys.path.append(str(Path(__file__).parent.parent))

from qualys_scanner_aci import QScannerACI
from image_parser import ImageParser
from storage_handler import StorageHandler


def main(event: func.EventGridEvent):
    try:
        event_data = event.get_json()
        event_type = event.event_type
        subject = event.subject

        # Log ALL events for debugging
        logging.info(f'=== EVENT GRID EVENT RECEIVED ===')
        logging.info(f'Event Type: {event_type}')
        logging.info(f'Subject: {subject}')
        logging.info(f'Event Data Keys: {list(event_data.keys())}')
        logging.info(f'Full Event: {json.dumps(event_data, indent=2)}')

        # Filter for container events (moved from Event Grid advanced filters)
        # Check if this is a container-related event
        # NOTE: These fields are at top level, not under 'data'
        resource_provider = event_data.get('resourceProvider', '')
        operation_name = event_data.get('operationName', '')
        resource_uri = event_data.get('resourceUri', '')

        logging.info(f'Resource Provider: {resource_provider}')
        logging.info(f'Operation Name: {operation_name}')
        logging.info(f'Resource URI: {resource_uri}')

        if 'Microsoft.ContainerInstance/containerGroups' in subject:
            container_type = 'ACI'
        elif 'Microsoft.App/containerApps' in subject:
            container_type = 'ACA'
        else:
            logging.info(f'Skipping non-container event (subject: {subject})')
            return

        logging.info(f'Processing {container_type} container event')

        event_subscription_id = event_data.get('subscriptionId')
        if event_subscription_id:
            logging.info(f'Event from subscription: {event_subscription_id}')

        # Extract resource group and container name from the resource URI
        resource_group = extract_resource_group(subject)
        container_name = subject.split('/')[-1]

        logging.info(f'Resource Group: {resource_group}')
        logging.info(f'Container Name: {container_name}')

        # Fetch container details from Azure
        images = fetch_container_images(event_subscription_id, resource_group, container_name, container_type)

        if not images:
            logging.warning('No container images found in container')
            return

        logging.info(f'Found {len(images)} container images to scan')

        scanner = QScannerACI(subscription_id=event_subscription_id)

        storage = StorageHandler(
            connection_string=os.environ['STORAGE_CONNECTION_STRING']
        )

        results = []
        for image in images:
            logging.info(f'Processing image: {image}')

            try:
                image_info = ImageParser.parse(image)

                if storage.is_recently_scanned(image_info['full_name']):
                    logging.info(f'Image {image} was recently scanned, skipping')
                    continue

                custom_tags = {
                    'container_type': container_type,
                    'azure_subscription': event_data.get('subscriptionId', 'unknown'),
                    'resource_group': extract_resource_group(subject),
                    'event_id': event.id
                }

                scan_result = scanner.scan_image(
                    registry=image_info['registry'],
                    repository=image_info['repository'],
                    tag=image_info['tag'],
                    digest=image_info.get('digest'),
                    custom_tags=custom_tags
                )

                result_record = {
                    'timestamp': datetime.utcnow().isoformat(),
                    'container_type': container_type,
                    'image': image,
                    'event_subject': subject,
                    'scan_id': scan_result.get('scan_id'),
                    'status': scan_result.get('status'),
                    'vulnerabilities': scan_result.get('vulnerabilities', {}),
                    'compliance': scan_result.get('compliance', {})
                }

                storage.save_scan_result(result_record)
                results.append(result_record)

                if should_alert(result_record):
                    send_alert(result_record)

            except Exception as img_error:
                logging.error(f'Error processing image {image}: {str(img_error)}')
                storage.save_error({
                    'timestamp': datetime.utcnow().isoformat(),
                    'image': image,
                    'error': str(img_error),
                    'event_subject': subject
                })

        logging.info(f'Successfully processed {len(results)} images')

    except Exception as e:
        logging.error(f'Error processing event: {str(e)}')
        raise


def fetch_container_images(subscription_id: str, resource_group: str, container_name: str, container_type: str) -> list:
    """Fetch container images from Azure management API"""
    images = []

    try:
        from azure.identity import DefaultAzureCredential
        from azure.mgmt.containerinstance import ContainerInstanceManagementClient

        logging.info(f'Fetching container details from Azure for {container_name}')

        credential = DefaultAzureCredential()

        if container_type == 'ACI':
            # Fetch ACI container group details
            aci_client = ContainerInstanceManagementClient(credential, subscription_id)
            container_group = aci_client.container_groups.get(resource_group, container_name)

            logging.info(f'Retrieved container group: {container_group.name}')
            logging.info(f'Number of containers: {len(container_group.containers)}')

            for container in container_group.containers:
                if container.image:
                    logging.info(f'Found image: {container.image}')
                    images.append(container.image)

        elif container_type == 'ACA':
            # Fetch ACA container app details
            # Note: Would need ContainerAppsManagementClient for ACA
            logging.warning('ACA support not yet implemented')

    except Exception as e:
        logging.error(f'Error fetching container images from Azure: {str(e)}')
        import traceback
        logging.error(traceback.format_exc())

    return images


def should_alert(scan_result: dict) -> bool:
    notify_threshold = os.environ.get('NOTIFY_SEVERITY_THRESHOLD', 'HIGH')

    vulnerabilities = scan_result.get('vulnerabilities', {})
    critical_count = vulnerabilities.get('CRITICAL', 0)
    high_count = vulnerabilities.get('HIGH', 0)

    if notify_threshold == 'CRITICAL':
        return critical_count > 0
    elif notify_threshold == 'HIGH':
        return critical_count > 0 or high_count > 0

    return False


def extract_resource_group(subject: str) -> str:
    try:
        parts = subject.split('/')
        rg_index = parts.index('resourceGroups') + 1
        return parts[rg_index]
    except:
        return 'unknown'


def send_alert(scan_result: dict):
    try:
        notification_email = os.environ.get('NOTIFICATION_EMAIL')
        if not notification_email:
            logging.warning('NOTIFICATION_EMAIL not configured, skipping alert')
            return

        logging.warning(
            f'SECURITY ALERT: High severity vulnerabilities found in {scan_result["image"]}. '
            f'Vulnerabilities: {scan_result["vulnerabilities"]}'
        )

    except Exception as e:
        logging.error(f'Error sending alert: {str(e)}')
