"""
Azure Storage handler for scan results and metadata
"""
import os
import json
import logging
from datetime import datetime, timedelta
from typing import Dict, Optional
from azure.storage.blob import BlobServiceClient, BlobClient
from azure.data.tables import TableServiceClient, TableEntity
from azure.core.exceptions import ResourceNotFoundError
from azure.identity import DefaultAzureCredential


class StorageHandler:
    """
    Handles storage of scan results and tracking in Azure Storage
    Uses Blob Storage for detailed results and Table Storage for metadata
    Uses managed identity for authentication
    """

    def __init__(self, storage_account_name: Optional[str] = None):
        """
        Initialize storage handler with managed identity

        Args:
            storage_account_name: Azure Storage account name.
                                 If not provided, uses STORAGE_ACCOUNT_NAME env var.
        """
        self.storage_account_name = storage_account_name or os.environ.get('STORAGE_ACCOUNT_NAME')
        if not self.storage_account_name:
            raise ValueError('Storage account name must be provided or set in STORAGE_ACCOUNT_NAME env var')

        credential = DefaultAzureCredential()
        blob_url = f'https://{self.storage_account_name}.blob.core.windows.net'
        table_url = f'https://{self.storage_account_name}.table.core.windows.net'

        self.blob_service = BlobServiceClient(account_url=blob_url, credential=credential)
        self.table_service = TableServiceClient(endpoint=table_url, credential=credential)

        # Container and table names
        self.results_container = 'scan-results'
        self.metadata_table = 'ScanMetadata'

        # Initialize storage
        self._ensure_storage_exists()

    def _ensure_storage_exists(self):
        """Create blob container and table if they don't exist"""
        try:
            # Create blob container
            self.blob_service.create_container(self.results_container)
            logging.info(f'Created blob container: {self.results_container}')
        except Exception as e:
            logging.debug(f'Blob container already exists or error: {str(e)}')

        try:
            # Create table
            self.table_service.create_table(self.metadata_table)
            logging.info(f'Created table: {self.metadata_table}')
        except Exception as e:
            logging.debug(f'Table already exists or error: {str(e)}')

    def save_scan_result(self, result: Dict):
        """
        Save scan result to storage

        Args:
            result: Scan result dictionary
        """
        try:
            image = result.get('image', 'unknown')
            scan_id = result.get('scan_id', datetime.utcnow().strftime('%Y%m%d%H%M%S'))
            timestamp = result.get('timestamp', datetime.utcnow().isoformat())

            # Save detailed results to blob storage
            blob_name = f'{self._sanitize_name(image)}/{scan_id}.json'
            blob_client = self.blob_service.get_blob_client(
                container=self.results_container,
                blob=blob_name
            )

            blob_client.upload_blob(
                json.dumps(result, indent=2),
                overwrite=True,
                metadata={
                    'image': image,
                    'scan_id': scan_id,
                    'timestamp': timestamp
                }
            )

            logging.info(f'Saved scan result to blob: {blob_name}')

            # Save metadata to table storage
            table_client = self.table_service.get_table_client(self.metadata_table)

            entity = {
                'PartitionKey': self._sanitize_name(image),
                'RowKey': scan_id,
                'Image': image,
                'ScanId': scan_id,
                'ScanTimestamp': timestamp,
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
            logging.info(f'Saved scan metadata to table: {image}/{scan_id}')

        except Exception as e:
            logging.error(f'Error saving scan result: {str(e)}')
            raise

    def save_error(self, error_info: Dict):
        """
        Save error information

        Args:
            error_info: Error details dictionary
        """
        try:
            timestamp = error_info.get('timestamp', datetime.utcnow().isoformat())
            image = error_info.get('image', 'unknown')

            # Save to blob storage
            blob_name = f'errors/{self._sanitize_name(image)}/{timestamp}.json'
            blob_client = self.blob_service.get_blob_client(
                container=self.results_container,
                blob=blob_name
            )

            blob_client.upload_blob(
                json.dumps(error_info, indent=2),
                overwrite=True
            )

            logging.info(f'Saved error info to blob: {blob_name}')

        except Exception as e:
            logging.error(f'Error saving error info: {str(e)}')

    def is_recently_scanned(self, image: str, hours: Optional[int] = None) -> bool:
        """
        Check if an image was scanned recently

        Args:
            image: Image name
            hours: Number of hours to consider as "recent" (defaults to SCAN_CACHE_HOURS env var or 24)

        Returns:
            True if image was scanned within the specified time period
        """
        try:
            if hours is None:
                hours = int(os.environ.get('SCAN_CACHE_HOURS', '24'))

            table_client = self.table_service.get_table_client(self.metadata_table)
            partition_key = self._sanitize_name(image)
            cutoff_time = datetime.utcnow() - timedelta(hours=hours)

            # Query by partition key and check ScanTimestamp programmatically
            # Table Storage OData filters don't support custom datetime comparisons reliably
            query_filter = f"PartitionKey eq '{partition_key}'"
            entities = table_client.query_entities(query_filter=query_filter, select=['RowKey', 'ScanTimestamp'])

            for entity in entities:
                scan_timestamp_str = entity.get('ScanTimestamp')
                if scan_timestamp_str:
                    try:
                        scan_timestamp = datetime.fromisoformat(scan_timestamp_str.replace('Z', '+00:00'))
                        if scan_timestamp >= cutoff_time:
                            logging.info(f'Found recent scan for {image} at {scan_timestamp_str}')
                            return True
                    except (ValueError, AttributeError) as parse_error:
                        logging.warning(f'Failed to parse ScanTimestamp: {scan_timestamp_str}, error: {parse_error}')
                        continue

            return False

        except Exception as e:
            logging.warning(f'Error checking recent scans: {str(e)}')
            return False

    def _sanitize_name(self, name: str) -> str:
        """
        Sanitize name for use as partition key or blob name

        Args:
            name: Original name

        Returns:
            Sanitized name
        """
        # Replace special characters with underscores
        sanitized = name.replace('/', '_').replace(':', '_').replace('@', '_')
        # Remove any remaining invalid characters
        sanitized = ''.join(c if c.isalnum() or c in '-_.' else '_' for c in sanitized)
        return sanitized
