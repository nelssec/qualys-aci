import os
import json
import logging
import azure.functions as func
from datetime import datetime

from image_parser import ImageParser
from storage_handler import StorageHandler
from qualys_api import get_or_create_registry, submit_on_demand_scan

app = func.FunctionApp()

QUALYS_GATEWAY_URL = os.environ.get('QUALYS_GATEWAY_URL', 'https://gateway.qg2.apps.qualys.com')
QUALYS_API_TOKEN = os.environ.get('QUALYS_API_TOKEN')
ACR_CONNECTOR_NAME = os.environ.get('ACR_CONNECTOR_NAME', 'qualys-aci-connector')
ACR_APPLICATION_ID = os.environ.get('ACR_APPLICATION_ID')
ACR_CLIENT_SECRET = os.environ.get('ACR_CLIENT_SECRET')
SERVICEBUS_CONNECTION_STRING = os.environ.get('SERVICEBUS_CONNECTION_STRING')
SERVICEBUS_QUEUE_NAME = os.environ.get('SERVICEBUS_QUEUE_NAME', 'scan-notifications')


def send_notification(message: dict):
    if not SERVICEBUS_CONNECTION_STRING:
        return
    try:
        from azure.servicebus import ServiceBusClient, ServiceBusMessage
        with ServiceBusClient.from_connection_string(SERVICEBUS_CONNECTION_STRING) as client:
            with client.get_queue_sender(SERVICEBUS_QUEUE_NAME) as sender:
                sender.send_messages(ServiceBusMessage(json.dumps(message)))
        logging.info(f'Notification sent: {message.get("type")}')
    except Exception as e:
        logging.warning(f'Failed to send notification: {str(e)}')


def fetch_container_images(subscription_id: str, resource_group: str,
                           container_name: str, container_type: str) -> list:
    images = []
    try:
        from azure.identity import DefaultAzureCredential
        credential = DefaultAzureCredential()

        if container_type == 'ACI':
            from azure.mgmt.containerinstance import ContainerInstanceManagementClient
            client = ContainerInstanceManagementClient(credential, subscription_id)
            container_group = client.container_groups.get(resource_group, container_name)
            for container in container_group.containers:
                if container.image:
                    images.append(container.image)

        elif container_type == 'ACA':
            from azure.mgmt.appcontainers import ContainerAppsAPIClient
            client = ContainerAppsAPIClient(credential, subscription_id)
            container_app = client.container_apps.get(resource_group, container_name)
            if container_app.template and container_app.template.containers:
                for container in container_app.template.containers:
                    if container.image:
                        images.append(container.image)

    except Exception as e:
        logging.error(f'Failed to fetch container images: {type(e).__name__}: {str(e)}')

    return images


def is_acr_image(registry: str) -> bool:
    return registry.endswith('.azurecr.io')


def process_activity_log_record(record: dict):
    try:
        operation_name = record.get('operationName', {})
        if isinstance(operation_name, dict):
            operation_name = operation_name.get('value', '')

        result_type = record.get('resultType', '') or record.get('status', {}).get('value', '')
        resource_id = record.get('resourceId', '')

        is_aci = 'CONTAINERINSTANCE/CONTAINERGROUPS/WRITE' in operation_name.upper()
        is_aca = 'APP/CONTAINERAPPS/WRITE' in operation_name.upper()

        if not (is_aci or is_aca) or result_type.upper() not in ['SUCCESS', 'SUCCEEDED']:
            return

        container_type = 'ACI' if is_aci else 'ACA'
        logging.info(f'Container creation detected: {container_type}')

        resource_parts = resource_id.split('/')
        subscription_id = resource_parts[2] if len(resource_parts) > 2 else None

        try:
            rg_idx = [p.lower() for p in resource_parts].index('resourcegroups') + 1
            resource_group = resource_parts[rg_idx]
        except (ValueError, IndexError):
            logging.error(f'Failed to extract resource group from: {resource_id}')
            return

        container_name = resource_parts[-1]
        images = fetch_container_images(subscription_id, resource_group, container_name, container_type)

        if not images:
            logging.warning('No container images found')
            return

        logging.info(f'Found {len(images)} images to scan')
        storage = StorageHandler(connection_string=os.environ['STORAGE_CONNECTION_STRING'])

        for image in images:
            try:
                process_image(image, resource_id, container_type, storage)
            except Exception as img_error:
                logging.error(f'Failed to process image {image}: {str(img_error)}')
                storage.save_error({
                    'timestamp': datetime.utcnow().isoformat(),
                    'image': image,
                    'error': str(img_error),
                    'resource_id': resource_id
                })

    except Exception as e:
        logging.error(f'Error processing activity log record: {str(e)}')
        import traceback
        logging.error(traceback.format_exc())


def process_image(image: str, resource_id: str, container_type: str, storage: StorageHandler):
    logging.info(f'Processing image: {image}')

    image_info = ImageParser.parse(image)
    registry = image_info['registry']
    repository = image_info['repository']
    tag = image_info['tag']

    if not is_acr_image(registry):
        logging.info(f'Skipping non-ACR image: {registry}')
        return

    if storage.is_recently_scanned(image_info['full_name']):
        logging.info('Image recently scanned, skipping')
        return

    registry_name = f"acr-{registry.split('.')[0]}"

    registry_result = get_or_create_registry(
        gateway_url=QUALYS_GATEWAY_URL,
        token=QUALYS_API_TOKEN,
        registry_name=registry_name,
        acr_login_server=registry,
        connector_name=ACR_CONNECTOR_NAME,
        application_id=ACR_APPLICATION_ID,
        client_secret=ACR_CLIENT_SECRET
    )

    if not registry_result.get('registry_uuid'):
        raise Exception(f"Failed to get/create registry: {registry_result.get('error')}")

    registry_uuid = registry_result['registry_uuid']

    scan_result = submit_on_demand_scan(
        gateway_url=QUALYS_GATEWAY_URL,
        token=QUALYS_API_TOKEN,
        registry_uuid=registry_uuid,
        repo_name=repository,
        image_tag=tag
    )

    if not scan_result.get('success'):
        raise Exception(f"Failed to submit scan: HTTP {scan_result.get('status_code')}")

    logging.info(f'Scan submitted: {scan_result.get("schedule_name")}')

    result_record = {
        'timestamp': datetime.utcnow().isoformat(),
        'container_type': container_type,
        'image': image,
        'resource_id': resource_id,
        'scan_id': scan_result.get('schedule_name'),
        'status': 'SUBMITTED',
        'registry_uuid': registry_uuid,
        'scan_method': 'registry_api'
    }

    storage.save_scan_result(result_record)

    send_notification({
        'type': 'scan_submitted',
        'timestamp': result_record['timestamp'],
        'image': image,
        'container_type': container_type,
        'resource_id': resource_id,
        'scan_id': scan_result.get('schedule_name')
    })


@app.function_name(name="ActivityLogProcessor")
@app.event_hub_message_trigger(
    arg_name="event",
    event_hub_name="activity-log",
    connection="EVENTHUB_CONNECTION_STRING",
    cardinality=func.Cardinality.ONE
)
def activity_log_processor(event: func.EventHubEvent):
    logging.info('Activity Log event received')

    try:
        event_body = event.get_body().decode('utf-8')
        event_data = json.loads(event_body)

        records = event_data.get('records', [])
        if not records:
            return

        logging.info(f'Processing {len(records)} Activity Log records')

        for record in records:
            process_activity_log_record(record)

    except Exception as e:
        logging.error(f'Activity log processing failed: {str(e)}')
        import traceback
        logging.error(traceback.format_exc())
        raise
