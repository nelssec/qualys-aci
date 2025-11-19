"""
Qualys qscanner integration using ACI containers
Spawns ACI containers with Docker to run qscanner scans
Much simpler than trying to run qscanner in Azure Functions without Docker
"""
import os
import logging
from typing import Dict, Optional
from datetime import datetime
from azure.mgmt.containerinstance import ContainerInstanceManagementClient
from azure.mgmt.containerinstance.models import (
    Container,
    ContainerGroup,
    ContainerGroupRestartPolicy,
    ContainerGroupIdentity,
    ResourceIdentityType,
    OperatingSystemTypes,
    ResourceRequirements,
    ResourceRequests,
    EnvironmentVariable,
    ImageRegistryCredential
)
from azure.identity import DefaultAzureCredential


class QScannerACI:
    """
    Run qscanner scans using ACI containers with Docker

    Architecture:
    1. Azure Function processes Activity Log events
    2. For each container image, spawn an ACI container
    3. ACI container runs qscanner with Docker available
    4. qscanner uploads results to Qualys
    5. ACI container exits (auto-cleanup with Never restart policy)
    """

    def __init__(self):
        """Initialize ACI scanner with Azure credentials"""
        self.subscription_id = os.environ.get('AZURE_SUBSCRIPTION_ID')
        self.resource_group = os.environ.get('SCANNER_RESOURCE_GROUP', 'qualys-scanner-rg')
        self.location = os.environ.get('SCANNER_LOCATION', 'eastus')

        # Qualys configuration
        self.qualys_pod = os.environ.get('QUALYS_POD')
        self.qualys_access_token = os.environ.get('QUALYS_ACCESS_TOKEN')

        # Use docker:dind image from Azure Container Registry (ACR)
        # to avoid Docker Hub rate limiting. We'll download qscanner binary at runtime.
        # ACR authentication happens automatically via Azure - no credentials needed!
        acr_server = os.environ.get('ACR_SERVER')
        if acr_server:
            self.qscanner_image = os.environ.get('QSCANNER_IMAGE', f'{acr_server}/docker:24.0-dind')
        else:
            # Fallback to Docker Hub (not recommended due to rate limiting)
            self.qscanner_image = os.environ.get('QSCANNER_IMAGE', 'docker:24.0-dind')

        # Azure client
        self.credential = DefaultAzureCredential()
        self.aci_client = ContainerInstanceManagementClient(
            credential=self.credential,
            subscription_id=self.subscription_id
        )

        logging.info(f'Initialized ACI scanner: subscription={self.subscription_id}, rg={self.resource_group}')

    def scan_image(self, registry: str, repository: str, tag: str = 'latest',
                   digest: Optional[str] = None, resource_id: Optional[str] = None) -> Dict:
        """
        Scan a container image by spawning an ACI container

        Args:
            registry: Container registry
            repository: Image repository
            tag: Image tag
            digest: Optional image digest
            resource_id: Optional Azure resource ID for tracking

        Returns:
            Dictionary containing scan information
        """
        # Construct image identifier
        image_id = f'{registry}/{repository}:{tag}'
        if digest:
            image_id = f'{registry}/{repository}@{digest}'

        # Generate unique container name
        timestamp = int(datetime.utcnow().timestamp())
        container_name = f'qscan-{timestamp}'

        logging.info(f'Creating ACI container to scan: {image_id}')
        logging.info(f'Container name: {container_name}')

        try:
            # Create ACI container
            container_group = self._create_aci_container(
                container_name=container_name,
                image_to_scan=image_id,
                resource_id=resource_id
            )

            logging.info(f'ACI container created: {container_group.name}')
            logging.info(f'Provisioning state: {container_group.provisioning_state}')

            return {
                'scan_id': container_name,
                'status': 'SUBMITTED',
                'image': image_id,
                'container_group': container_group.name,
                'resource_id': container_group.id,
                'provisioning_state': container_group.provisioning_state,
                'metadata': {
                    'registry': registry,
                    'repository': repository,
                    'tag': tag,
                    'digest': digest,
                    'timestamp': datetime.utcnow().isoformat(),
                    'scanner': 'qscanner-aci'
                }
            }

        except Exception as e:
            logging.error(f'Failed to create ACI container: {str(e)}')
            raise

    def _create_aci_container(self, container_name: str, image_to_scan: str,
                             resource_id: Optional[str] = None) -> ContainerGroup:
        """
        Create ACI container group that runs qscanner with Docker-in-Docker

        Args:
            container_name: Name for the ACI container
            image_to_scan: Full image identifier to scan
            resource_id: Optional Azure resource ID for tagging

        Returns:
            Created ContainerGroup
        """
        # Build qscanner version
        qscanner_version = os.environ.get('QSCANNER_VERSION', '4.6.0-4')

        # Build script that:
        # 1. Starts Docker daemon in background
        # 2. Downloads qscanner binary
        # 3. Runs qscanner scan
        tags = f'scan_timestamp={datetime.utcnow().isoformat()}'
        if resource_id:
            tags += f',azure_resource_id={resource_id}'

        scan_script = f'''#!/bin/sh
set -e

echo "Starting Docker daemon..."
dockerd &
DOCKER_PID=$!

# Wait for Docker to be ready
echo "Waiting for Docker daemon to start..."
for i in $(seq 1 30); do
    if docker info >/dev/null 2>&1; then
        echo "Docker daemon is ready"
        break
    fi
    echo "Waiting for Docker... ($i/30)"
    sleep 2
done

# Download qscanner
echo "Downloading qscanner v{qscanner_version}..."
wget -O /tmp/qscanner.tar.gz "https://cask.qg1.apps.qualys.com/cs/p/MwmsS_SfM0RTBIc5r-hpCUmY34xkB4n93rJNAfOf_BH5BnExjNT7P-48_03RUMr_/n/qualysincgov/b/us01-cask-artifacts/o/cs/qscanner/{qscanner_version}/qscanner-{qscanner_version}.linux-amd64.tar.gz"

echo "Extracting qscanner..."
tar -xzf /tmp/qscanner.tar.gz -C /usr/local/bin/
chmod +x /usr/local/bin/qscanner

echo "Running qscanner scan on {image_to_scan}..."
qscanner image "{image_to_scan}" \\
    --pod "{self.qualys_pod}" \\
    --scan-types os,sca,secret \\
    --format json \\
    --access-token "{self.qualys_access_token}" \\
    --save \\
    --skip-verify-tls \\
    --tag "{tags}" || echo "Scan completed with exit code $?"

echo "Scan complete. Stopping Docker daemon..."
kill $DOCKER_PID 2>/dev/null || true
'''

        # Use sh to run the script
        command = ['sh', '-c', scan_script]

        # Container configuration
        container = Container(
            name=container_name,
            image=self.qscanner_image,
            command=command,
            resources=ResourceRequirements(
                requests=ResourceRequests(
                    memory_in_gb=4.0,  # Increased for Docker daemon + image pulls + scanning
                    cpu=2.0  # Increased for faster Docker operations
                )
            ),
            environment_variables=[]
        )

        # User-assigned managed identity for ACR authentication
        # This identity has AcrPull role on the ACR and is used to pull docker:dind image
        identity_resource_id = f'/subscriptions/{self.subscription_id}/resourcegroups/{self.resource_group}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/qscan-aci-identity'

        identity = ContainerGroupIdentity(
            type=ResourceIdentityType.user_assigned,
            user_assigned_identities={
                identity_resource_id: {}
            }
        )

        # ImageRegistryCredential using managed identity for ACR authentication
        # The identity parameter tells ACI to use this managed identity to pull from ACR
        acr_server = os.environ.get('ACR_SERVER', 'qscanacralo13zi.azurecr.io')
        registry_credentials = [
            ImageRegistryCredential(
                server=acr_server,
                identity=identity_resource_id
            )
        ]

        # Container group configuration with managed identity for ACR authentication
        container_group = ContainerGroup(
            location=self.location,
            containers=[container],
            os_type=OperatingSystemTypes.linux,
            restart_policy=ContainerGroupRestartPolicy.never,  # Run once and exit
            identity=identity,  # Assign managed identity to container group
            image_registry_credentials=registry_credentials,  # Use managed identity for ACR auth
            tags={
                'purpose': 'qualys-scan',
                'image': image_to_scan,
                'timestamp': str(datetime.utcnow().timestamp())
            }
        )

        # Create container group
        logging.info(f'Creating container group: {container_name}')
        logging.info(f'Command: qscanner image {image_to_scan} --pod {self.qualys_pod} ...')

        result = self.aci_client.container_groups.begin_create_or_update(
            resource_group_name=self.resource_group,
            container_group_name=container_name,
            container_group=container_group
        )

        # Wait for creation to complete (non-blocking for function)
        return result.result()
