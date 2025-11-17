"""
Container image name parser
Handles various image name formats from different registries
"""
import re
from typing import Dict


class ImageParser:
    """
    Parse container image names into components
    Supports Docker Hub, Azure Container Registry, and other registries
    """

    @staticmethod
    def parse(image_name: str) -> Dict:
        """
        Parse a container image name into components

        Args:
            image_name: Full image name (e.g., docker.io/library/nginx:latest)

        Returns:
            Dictionary with parsed components:
                - registry: Registry hostname
                - repository: Repository path
                - tag: Image tag
                - digest: Image digest (if present)
                - full_name: Complete image identifier

        Examples:
            nginx -> docker.io/library/nginx:latest
            myacr.azurecr.io/app:v1 -> myacr.azurecr.io/app:v1
            mcr.microsoft.com/dotnet/runtime:6.0 -> mcr.microsoft.com/dotnet/runtime:6.0
            nginx@sha256:abc123 -> docker.io/library/nginx@sha256:abc123
        """
        # Handle digest format (image@sha256:...)
        digest = None
        if '@sha256:' in image_name:
            image_name, digest = image_name.split('@sha256:')
            digest = f'sha256:{digest}'

        # Split tag from image name
        tag = 'latest'
        if ':' in image_name:
            image_name, tag = image_name.rsplit(':', 1)

        # Parse registry and repository
        parts = image_name.split('/')

        if len(parts) == 1:
            # Simple name like "nginx"
            registry = 'docker.io'
            repository = f'library/{parts[0]}'
        elif len(parts) == 2:
            # Could be "user/repo" or "registry/repo"
            if '.' in parts[0] or ':' in parts[0]:
                # Has registry (contains . or port)
                registry = parts[0]
                repository = parts[1]
            else:
                # Docker Hub user repository
                registry = 'docker.io'
                repository = f'{parts[0]}/{parts[1]}'
        else:
            # Full path with registry
            registry = parts[0]
            repository = '/'.join(parts[1:])

        # Construct full name
        full_name = f'{registry}/{repository}:{tag}'
        if digest:
            full_name = f'{registry}/{repository}@{digest}'

        return {
            'registry': registry,
            'repository': repository,
            'tag': tag,
            'digest': digest,
            'full_name': full_name,
            'original': image_name if not digest else f'{image_name}@{digest}'
        }

    @staticmethod
    def is_azure_registry(registry: str) -> bool:
        """
        Check if registry is an Azure Container Registry

        Args:
            registry: Registry hostname

        Returns:
            True if Azure Container Registry
        """
        return registry.endswith('.azurecr.io')

    @staticmethod
    def is_microsoft_registry(registry: str) -> bool:
        """
        Check if registry is a Microsoft Container Registry

        Args:
            registry: Registry hostname

        Returns:
            True if Microsoft Container Registry
        """
        return registry in ['mcr.microsoft.com', 'mcr.microsoft.azure.com']

    @staticmethod
    def normalize_image_name(image_name: str) -> str:
        """
        Normalize image name to fully qualified format

        Args:
            image_name: Image name in any format

        Returns:
            Fully qualified image name
        """
        parsed = ImageParser.parse(image_name)
        return parsed['full_name']
