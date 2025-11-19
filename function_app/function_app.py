import os
import json
import logging
import azure.functions as func
from datetime import datetime

# Import helper modules
from qualys_scanner_binary import QScannerBinary
from image_parser import ImageParser
from storage_handler import StorageHandler

app = func.FunctionApp()


@app.function_name(name="EventProcessor")
@app.event_grid_trigger(arg_name="event")
def event_processor(event: func.EventGridEvent):
    """Process Event Grid events for container deployments"""
    logging.info('EVENT GRID TRIGGER: Function started')

    try:
        event_data = event.get_json()
        event_type = event.event_type
        subject = event.subject

        logging.info(f'EVENT GRID EVENT RECEIVED')
        logging.info(f'Event Type: {event_type}')
        logging.info(f'Subject: {subject}')
        logging.info(f'Event ID: {event.id}')
        logging.info(f'Event Data Keys: {list(event_data.keys())}')

        # Filter for container events
        if 'Microsoft.ContainerInstance/containerGroups' in subject:
            container_type = 'ACI'
            logging.info('Event matched: Azure Container Instance')
        elif 'Microsoft.App/containerApps' in subject:
            container_type = 'ACA'
            logging.info('Event matched: Azure Container Apps')
        else:
            logging.info(f'EVENT SKIPPED: Non-container event (subject: {subject})')
            return

        logging.info(f'PROCESSING: {container_type} container event')

        event_subscription_id = event_data.get('subscriptionId')
        resource_group = extract_resource_group(subject)
        container_name = subject.split('/')[-1]

        logging.info(f'Subscription ID: {event_subscription_id}')
        logging.info(f'Resource Group: {resource_group}')
        logging.info(f'Container Name: {container_name}')

        # Skip qscanner containers to prevent infinite loops
        if container_name.startswith('qscanner-'):
            logging.info(f'EVENT SKIPPED: qscanner container (prevents infinite loop): {container_name}')
            return

        # Fetch container details from Azure
        logging.info(f'FETCHING: Container details from Azure Management API')
        images = fetch_container_images(event_subscription_id, resource_group, container_name, container_type)

        if not images:
            logging.warning('FETCH FAILED: No container images found in container')
            return

        logging.info(f'FETCH SUCCESS: Found {len(images)} container images to scan')
        for idx, img in enumerate(images):
            logging.info(f'  Image {idx + 1}: {img}')

        logging.info('INITIALIZING: QScanner binary and storage handler')
        scanner = QScannerBinary(subscription_id=event_subscription_id)
        storage = StorageHandler(connection_string=os.environ['STORAGE_CONNECTION_STRING'])
        logging.info('INITIALIZED: Ready to scan images')

        results = []
        for idx, image in enumerate(images):
            logging.info(f'SCANNING IMAGE {idx + 1}/{len(images)}: {image}')

            try:
                logging.info(f'  Parsing image identifier')
                image_info = ImageParser.parse(image)
                logging.info(f'  Parsed: registry={image_info.get("registry")}, repo={image_info.get("repository")}, tag={image_info.get("tag")}')

                if storage.is_recently_scanned(image_info['full_name']):
                    logging.info(f'  SCAN SKIPPED: Image was recently scanned (cache hit)')
                    continue

                logging.info(f'  Starting scan with qscanner binary')

                custom_tags = {
                    'container_type': container_type,
                    'azure_subscription': event_data.get('subscriptionId', 'unknown'),
                    'resource_group': resource_group,
                    'event_id': event.id
                }

                scan_result = scanner.scan_image(
                    registry=image_info['registry'],
                    repository=image_info['repository'],
                    tag=image_info['tag'],
                    digest=image_info.get('digest'),
                    custom_tags=custom_tags
                )

                logging.info(f'  SCAN COMPLETED: status={scan_result.get("status")}, scan_id={scan_result.get("scan_id")}')
                vuln_summary = scan_result.get('vulnerabilities', {})
                logging.info(f'  Vulnerabilities: Critical={vuln_summary.get("CRITICAL", 0)}, High={vuln_summary.get("HIGH", 0)}, Medium={vuln_summary.get("MEDIUM", 0)}, Low={vuln_summary.get("LOW", 0)}')

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

                logging.info(f'  SAVING: Scan results to storage')
                storage.save_scan_result(result_record)
                results.append(result_record)
                logging.info(f'  SAVED: Scan result saved successfully')

                if should_alert(result_record):
                    logging.info(f'  ALERT: High severity findings detected, sending notification')
                    send_alert(result_record)

            except Exception as img_error:
                logging.error(f'SCAN ERROR: Failed to process image {image}')
                logging.error(f'  Error: {str(img_error)}')
                import traceback
                logging.error(f'  Traceback: {traceback.format_exc()}')
                storage.save_error({
                    'timestamp': datetime.utcnow().isoformat(),
                    'image': image,
                    'error': str(img_error),
                    'event_subject': subject
                })

        logging.info(f'PROCESSING COMPLETE: Successfully processed {len(results)} images')

    except Exception as e:
        logging.error(f'CRITICAL ERROR: Event processing failed')
        logging.error(f'  Error: {str(e)}')
        import traceback
        logging.error(f'  Traceback: {traceback.format_exc()}')
        raise


def fetch_container_images(subscription_id: str, resource_group: str, container_name: str, container_type: str) -> list:
    """Fetch container images from Azure management API"""
    images = []

    try:
        logging.info(f'API FETCH: Importing Azure SDK libraries')
        from azure.identity import DefaultAzureCredential
        from azure.mgmt.containerinstance import ContainerInstanceManagementClient

        logging.info(f'API FETCH: Authenticating with Azure using managed identity')
        logging.info(f'  Target: {container_type} container {container_name} in {resource_group}')
        logging.info(f'  Subscription: {subscription_id}')

        credential = DefaultAzureCredential()

        if container_type == 'ACI':
            logging.info(f'API FETCH: Creating ACI management client')
            aci_client = ContainerInstanceManagementClient(credential, subscription_id)

            logging.info(f'API FETCH: Calling container_groups.get()')
            container_group = aci_client.container_groups.get(resource_group, container_name)

            logging.info(f'API FETCH SUCCESS: Retrieved container group {container_group.name}')
            logging.info(f'  Provisioning State: {container_group.provisioning_state}')
            logging.info(f'  Number of containers: {len(container_group.containers)}')

            for idx, container in enumerate(container_group.containers):
                if container.image:
                    logging.info(f'  Container {idx + 1}: name={container.name}, image={container.image}')
                    images.append(container.image)
                else:
                    logging.warning(f'  Container {idx + 1}: name={container.name} has no image')

        elif container_type == 'ACA':
            logging.warning('API FETCH SKIPPED: ACA support not yet implemented')

    except Exception as e:
        logging.error(f'API FETCH ERROR: Failed to retrieve container images from Azure')
        logging.error(f'  Error type: {type(e).__name__}')
        logging.error(f'  Error message: {str(e)}')
        import traceback
        logging.error(f'  Traceback: {traceback.format_exc()}')

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
    """Extract resource group name from Azure resource URI (case-insensitive)"""
    try:
        parts = subject.split('/')
        parts_lower = [p.lower() for p in parts]
        rg_index = parts_lower.index('resourcegroups') + 1
        return parts[rg_index]
    except Exception as e:
        logging.error(f'Failed to extract resource group from subject: {subject}, error: {e}')
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
