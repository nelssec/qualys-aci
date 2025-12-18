import os
import json
import logging
from datetime import datetime, timedelta
from typing import Dict, Optional
from azure.storage.blob import BlobServiceClient
from azure.data.tables import TableServiceClient


class StorageHandler:
    def __init__(self, connection_string: str):
        self.connection_string = connection_string
        self.blob_service = BlobServiceClient.from_connection_string(connection_string)
        self.table_service = TableServiceClient.from_connection_string(connection_string)
        self.results_container = 'scan-results'
        self.metadata_table = 'ScanMetadata'
        self._ensure_storage_exists()

    def _ensure_storage_exists(self):
        try:
            self.blob_service.create_container(self.results_container)
        except Exception:
            pass
        try:
            self.table_service.create_table(self.metadata_table)
        except Exception:
            pass

    def save_scan_result(self, result: Dict):
        try:
            image = result.get('image', 'unknown')
            scan_id = result.get('scan_id', datetime.utcnow().strftime('%Y%m%d%H%M%S'))
            timestamp = result.get('timestamp', datetime.utcnow().isoformat())

            blob_name = f'{self._sanitize_name(image)}/{scan_id}.json'
            blob_client = self.blob_service.get_blob_client(container=self.results_container, blob=blob_name)

            blob_client.upload_blob(
                json.dumps(result, indent=2),
                overwrite=True,
                metadata={'image': image, 'scan_id': scan_id, 'timestamp': timestamp}
            )

            table_client = self.table_service.get_table_client(self.metadata_table)
            entity = {
                'PartitionKey': self._sanitize_name(image),
                'RowKey': scan_id,
                'Image': image,
                'ScanId': scan_id,
                'Timestamp': timestamp,
                'Status': result.get('status', 'UNKNOWN'),
                'ContainerType': result.get('container_type', 'UNKNOWN'),
                'VulnCritical': result.get('vulnerabilities', {}).get('CRITICAL', 0),
                'VulnHigh': result.get('vulnerabilities', {}).get('HIGH', 0),
                'VulnMedium': result.get('vulnerabilities', {}).get('MEDIUM', 0),
                'VulnLow': result.get('vulnerabilities', {}).get('LOW', 0),
                'VulnTotal': result.get('vulnerabilities', {}).get('total', 0),
                'CompliancePassed': result.get('compliance', {}).get('passed', 0),
                'ComplianceFailed': result.get('compliance', {}).get('failed', 0),
                'BlobPath': blob_name
            }
            table_client.upsert_entity(entity)
            logging.info(f'Saved scan result: {image}/{scan_id}')
        except Exception as e:
            logging.error(f'Error saving scan result: {str(e)}')
            raise

    def save_error(self, error_info: Dict):
        try:
            timestamp = error_info.get('timestamp', datetime.utcnow().isoformat())
            image = error_info.get('image', 'unknown')
            blob_name = f'errors/{self._sanitize_name(image)}/{timestamp}.json'
            blob_client = self.blob_service.get_blob_client(container=self.results_container, blob=blob_name)
            blob_client.upload_blob(json.dumps(error_info, indent=2), overwrite=True)
        except Exception as e:
            logging.error(f'Error saving error info: {str(e)}')

    def is_recently_scanned(self, image: str, hours: Optional[int] = None) -> bool:
        try:
            if hours is None:
                hours = int(os.environ.get('SCAN_CACHE_HOURS', '24'))

            table_client = self.table_service.get_table_client(self.metadata_table)
            partition_key = self._sanitize_name(image)
            cutoff_time = datetime.utcnow() - timedelta(hours=hours)

            query_filter = f"PartitionKey eq '{partition_key}' and Timestamp ge datetime'{cutoff_time.isoformat()}'"
            entities = list(table_client.query_entities(query_filter=query_filter, select=['RowKey']))

            if entities:
                logging.info(f'Found {len(entities)} recent scans for {image}')
                return True
            return False
        except Exception as e:
            logging.warning(f'Error checking recent scans: {str(e)}')
            return False

    def _sanitize_name(self, name: str) -> str:
        sanitized = name.replace('/', '_').replace(':', '_').replace('@', '_')
        return ''.join(c if c.isalnum() or c in '-_.' else '_' for c in sanitized)
