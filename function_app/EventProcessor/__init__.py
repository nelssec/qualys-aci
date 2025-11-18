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
    logging.info(f'Python EventGrid trigger processed an event: {event.get_json()}')

    try:
        event_data = event.get_json()
        event_type = event.event_type
        subject = event.subject

        logging.info(f'Event Type: {event_type}')
        logging.info(f'Subject: {subject}')

        event_subscription_id = event_data.get('subscriptionId')
        if event_subscription_id:
            logging.info(f'Event from subscription: {event_subscription_id}')

        if 'Microsoft.ContainerInstance/containerGroups' in subject:
            container_type = 'ACI'
        elif 'Microsoft.App/containerApps' in subject:
            container_type = 'ACA'
        else:
            logging.warning(f'Unknown container type in subject: {subject}')
            return

        images = extract_images(event_data, container_type)

        if not images:
            logging.warning('No container images found in event data')
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


def extract_images(event_data: dict, container_type: str) -> list:
    images = []

    try:
        if container_type == 'ACI':
            containers = event_data.get('data', {}).get('properties', {}).get('containers', [])
            for container in containers:
                image = container.get('properties', {}).get('image')
                if image:
                    images.append(image)

        elif container_type == 'ACA':
            template = event_data.get('data', {}).get('properties', {}).get('template', {})
            containers = template.get('containers', [])
            for container in containers:
                image = container.get('image')
                if image:
                    images.append(image)

    except Exception as e:
        logging.error(f'Error extracting images: {str(e)}')

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
