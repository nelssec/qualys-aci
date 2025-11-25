import os
import json
import logging
import re
import azure.functions as func
from datetime import datetime

# Import helper modules
from qualys_scanner_binary import QScannerBinary
from image_parser import ImageParser
from storage_handler import StorageHandler

app = func.FunctionApp()


# Security constants for input validation
# Azure container name constraints: 1-63 chars, lowercase alphanumeric and hyphens, can't start/end with hyphen
CONTAINER_NAME_PATTERN = re.compile(r'^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$')
# Azure resource group constraints: 1-90 chars, alphanumeric, underscores, hyphens, periods, parentheses
RESOURCE_GROUP_PATTERN = re.compile(r'^[-\w\._\(\)]{1,90}$')
# Azure subscription ID: GUID format
SUBSCRIPTION_ID_PATTERN = re.compile(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', re.IGNORECASE)


def validate_container_name(name: str) -> bool:
    """
    Validate container name follows Azure naming conventions.
    Defense-in-depth validation even though Activity Log is a trusted source.

    Args:
        name: Container name to validate

    Returns:
        True if valid, False otherwise
    """
    if not name or len(name) > 63:
        return False
    # Allow uppercase since Azure APIs may return mixed case
    return bool(CONTAINER_NAME_PATTERN.match(name.lower()))


def validate_resource_group(name: str) -> bool:
    """
    Validate resource group name follows Azure naming conventions.

    Args:
        name: Resource group name to validate

    Returns:
        True if valid, False otherwise
    """
    if not name or len(name) > 90:
        return False
    return bool(RESOURCE_GROUP_PATTERN.match(name))


def validate_subscription_id(sub_id: str) -> bool:
    """
    Validate subscription ID is a valid GUID format.

    Args:
        sub_id: Subscription ID to validate

    Returns:
        True if valid, False otherwise
    """
    if not sub_id:
        return False
    return bool(SUBSCRIPTION_ID_PATTERN.match(sub_id))


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
            logging.info(f'API FETCH: Creating ACA management client')
            from azure.mgmt.appcontainers import ContainerAppsAPIClient

            aca_client = ContainerAppsAPIClient(credential, subscription_id)

            logging.info(f'API FETCH: Calling container_apps.get()')
            container_app = aca_client.container_apps.get(resource_group, container_name)

            logging.info(f'API FETCH SUCCESS: Retrieved container app {container_app.name}')
            logging.info(f'  Provisioning State: {container_app.provisioning_state}')

            # Extract images from container app template
            if container_app.template and container_app.template.containers:
                logging.info(f'  Number of containers: {len(container_app.template.containers)}')
                for idx, container in enumerate(container_app.template.containers):
                    if container.image:
                        logging.info(f'  Container {idx + 1}: name={container.name}, image={container.image}')
                        images.append(container.image)
                    else:
                        logging.warning(f'  Container {idx + 1}: name={container.name} has no image')
            else:
                logging.warning('  No containers found in template')

    except Exception as e:
        logging.error(f'API FETCH ERROR: Failed to retrieve container images from Azure')
        logging.error(f'  Error type: {type(e).__name__}')
        logging.error(f'  Error message: {str(e)}')
        import traceback
        logging.error(f'  Traceback: {traceback.format_exc()}')

    return images


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


def process_activity_log_record(record: dict):
    """Process a single Activity Log record from diagnostic settings"""
    try:
        # Extract event details from diagnostic settings format
        operation_name = record.get('operationName', {})
        if isinstance(operation_name, dict):
            operation_name = operation_name.get('value', '')

        result_type = record.get('resultType', '') or record.get('status', {}).get('value', '')
        resource_id = record.get('resourceId', '')

        logging.info(f'Record: operation={operation_name}, result={result_type}, resource={resource_id}')

        # Check if this is a successful container creation event (ACI or ACA)
        is_aci = 'CONTAINERINSTANCE/CONTAINERGROUPS/WRITE' in operation_name.upper()
        is_aca = 'APP/CONTAINERAPPS/WRITE' in operation_name.upper()

        if (is_aci or is_aca) and result_type.upper() in ['SUCCESS', 'SUCCEEDED']:
            container_type = 'ACI' if is_aci else 'ACA'
            logging.info(f'EVENT MATCHED: {container_type} container creation detected')

            # Parse resource ID to extract subscription, resource group, and container name
            resource_parts = resource_id.split('/')
            subscription_id = resource_parts[2] if len(resource_parts) > 2 else None

            try:
                resource_group_idx = [p.lower() for p in resource_parts].index('resourcegroups') + 1
                resource_group = resource_parts[resource_group_idx]
            except (ValueError, IndexError):
                logging.error(f'Failed to extract resource group from resource ID: {resource_id}')
                return

            container_name = resource_parts[-1]

            logging.info(f'Subscription: {subscription_id}')
            logging.info(f'Resource Group: {resource_group}')
            logging.info(f'Container Name: {container_name}')

            # Input validation (defense-in-depth even for trusted Activity Log source)
            if not validate_subscription_id(subscription_id):
                logging.error(f'SECURITY: Invalid subscription ID format: {subscription_id}')
                return

            if not validate_resource_group(resource_group):
                logging.error(f'SECURITY: Invalid resource group name format: {resource_group}')
                return

            if not validate_container_name(container_name):
                logging.error(f'SECURITY: Invalid container name format: {container_name}')
                return

            # Skip qscanner containers to prevent infinite loops
            if container_name.lower().startswith('qscanner-'):
                logging.info(f'SKIPPED: qscanner container (prevents infinite loop)')
                return

            # Fetch container details from Azure
            logging.info('FETCHING: Container details from Azure Management API')
            images = fetch_container_images(subscription_id, resource_group, container_name, container_type)

            if not images:
                logging.warning('NO IMAGES: No container images found')
                return

            logging.info(f'FOUND: {len(images)} container images to scan')
            for idx, img in enumerate(images):
                logging.info(f'  Image {idx + 1}: {img}')

            # Initialize scanner and storage
            # Using remote registry scanning (Option 3) - no container runtime needed!
            scanner = QScannerBinary(subscription_id=subscription_id)
            storage = StorageHandler(connection_string=os.environ['STORAGE_CONNECTION_STRING'])

            # Scan each image
            results = []
            for idx, image in enumerate(images):
                logging.info(f'SCANNING IMAGE {idx + 1}/{len(images)}: {image}')

                try:
                    image_info = ImageParser.parse(image)
                    logging.info(f'  Parsed: registry={image_info.get("registry")}, repo={image_info.get("repository")}, tag={image_info.get("tag")}')

                    if storage.is_recently_scanned(image_info['full_name']):
                        logging.info(f'  CACHED: Image recently scanned')
                        continue

                    # Custom tags for tracking
                    custom_tags = {
                        'azure_resource_id': resource_id,
                        'container_type': container_type,
                        'scan_method': 'remote_registry'
                    }

                    scan_result = scanner.scan_image(
                        registry=image_info['registry'],
                        repository=image_info['repository'],
                        tag=image_info['tag'],
                        digest=image_info.get('digest'),
                        custom_tags=custom_tags
                    )

                    logging.info(f'  SCAN COMPLETED: scan_id={scan_result.get("scan_id")}')
                    logging.info(f'  Status: {scan_result.get("status")}')

                    vulnerabilities = scan_result.get('vulnerabilities', {})
                    logging.info(f'  Vulnerabilities: Critical={vulnerabilities.get("CRITICAL", 0)}, High={vulnerabilities.get("HIGH", 0)}')

                    result_record = {
                        'timestamp': datetime.utcnow().isoformat(),
                        'container_type': container_type,
                        'image': image,
                        'resource_id': resource_id,
                        'scan_id': scan_result.get('scan_id'),
                        'status': scan_result.get('status'),
                        'vulnerabilities': vulnerabilities,
                        'scan_method': 'remote_registry'
                    }

                    storage.save_scan_result(result_record)
                    results.append(result_record)
                    logging.info(f'  SAVED: Scan submission recorded')

                except Exception as img_error:
                    logging.error(f'SCAN ERROR: Failed to process image {image}')
                    logging.error(f'  Error: {str(img_error)}')
                    import traceback
                    logging.error(f'  Traceback: {traceback.format_exc()}')
                    storage.save_error({
                        'timestamp': datetime.utcnow().isoformat(),
                        'image': image,
                        'error': str(img_error),
                        'resource_id': resource_id
                    })

            logging.info(f'PROCESSING COMPLETE: Successfully processed {len(results)} images')
        else:
            logging.debug(f'EVENT SKIPPED: Not a container creation event')

    except Exception as e:
        logging.error(f'ERROR processing activity log record: {str(e)}')
        import traceback
        logging.error(f'Traceback: {traceback.format_exc()}')


@app.function_name(name="ActivityLogProcessor")
@app.event_hub_message_trigger(
    arg_name="event",
    event_hub_name="activity-log",
    connection="EVENTHUB_CONNECTION_STRING",
    cardinality=func.Cardinality.ONE
)
def activity_log_processor(event: func.EventHubEvent):
    """Process Activity Log events from Event Hub for container deployments"""
    logging.info('ACTIVITY LOG EVENT: Function triggered')

    try:
        event_body = event.get_body().decode('utf-8')
        event_data = json.loads(event_body)

        # Activity Log events from diagnostic settings come wrapped in a 'records' array
        records = event_data.get('records', [])
        if not records:
            logging.warning('No records found in event')
            return

        logging.info(f'Processing {len(records)} Activity Log records')

        # Process each record in the batch
        for record in records:
            process_activity_log_record(record)

    except Exception as e:
        logging.error(f'CRITICAL ERROR: Activity log processing failed')
        logging.error(f'  Error: {str(e)}')
        import traceback
        logging.error(f'  Traceback: {traceback.format_exc()}')
        raise
