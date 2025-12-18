from typing import Dict


class ImageParser:
    @staticmethod
    def parse(image_name: str) -> Dict:
        digest = None
        if '@sha256:' in image_name:
            image_name, digest = image_name.split('@sha256:')
            digest = f'sha256:{digest}'

        tag = 'latest'
        if ':' in image_name:
            image_name, tag = image_name.rsplit(':', 1)

        parts = image_name.split('/')

        if len(parts) == 1:
            registry = 'docker.io'
            repository = f'library/{parts[0]}'
        elif len(parts) == 2:
            if '.' in parts[0] or ':' in parts[0]:
                registry = parts[0]
                repository = parts[1]
            else:
                registry = 'docker.io'
                repository = f'{parts[0]}/{parts[1]}'
        else:
            registry = parts[0]
            repository = '/'.join(parts[1:])

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
