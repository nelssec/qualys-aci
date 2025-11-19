# Qualys Container Scanner Architecture

## Overview

This solution automatically scans container images deployed to Azure (ACI and ACA) using Qualys qscanner.

## Architecture

```
Azure Container Deployment
        ↓
Activity Log (Administrative Events)
        ↓
Diagnostic Settings
        ↓
Event Hub (activity-log)
        ↓
Azure Function (ActivityLogProcessor)
        ↓
Spawn ACI Container with Docker-in-Docker
        ↓
ACI: Start Docker daemon → Download qscanner → Pull target image → Scan → Upload to Qualys
```

## Key Components

### 1. Activity Log → Event Hub
- **Purpose**: Capture all container deployment events at subscription level
- **Configuration**: Diagnostic settings stream Activity Log to Event Hub
- **Latency**: 2-15 minutes (documented 2-5 min, observed 10-15 min)
- **Event Types**: `CONTAINERINSTANCE/CONTAINERGROUPS/WRITE`, `APP/CONTAINERAPPS/WRITE`

### 2. Azure Function (Consumption Plan)
- **Trigger**: Event Hub with `Cardinality.ONE` (single event processing)
- **Function**: `ActivityLogProcessor`
- **Purpose**:
  - Parse Activity Log events
  - Extract container image information via Azure Management API
  - Spawn ACI scanner containers
  - Track scans in Azure Storage

### 3. ACI Scanner Containers (Docker-in-Docker)
- **Base Image**: `docker:24.0-dind`
- **Why DinD**: qscanner requires Docker/containerd to pull and analyze images
- **Lifecycle**:
  1. Start Docker daemon in background
  2. Download qscanner binary from Qualys CASK CDN
  3. Pull target container image using Docker
  4. Run qscanner scan (os, sca, secret detection)
  5. Upload results to Qualys platform
  6. Exit (auto-cleanup with `restart_policy: never`)

### 4. Storage
- **Blob Storage**: Scan results and metadata
- **Table Storage**: Scan cache to prevent duplicate scans
- **Purpose**: Track scan history, enable querying, prevent re-scanning

## Why Docker-in-Docker?

qscanner cannot scan images from remote registries directly - it requires a local container runtime (Docker, containerd, or cri-o) to:
1. Pull the container image
2. Extract filesystem layers
3. Analyze packages, vulnerabilities, secrets

Azure Functions (Consumption Plan) doesn't have Docker available, so we use ACI containers with Docker-in-Docker to provide the required runtime environment.

## Cost Optimization

- **Per-scan pricing**: ACI containers run only during scans (~2-5 minutes)
- **Auto-cleanup**: Containers exit automatically after scan completion
- **Scan caching**: Table Storage prevents duplicate scans within configurable timeframe
- **Parallel execution**: Azure Functions auto-scale to process multiple deployments

## Scalability

- Event Hub: Handles high-throughput event streams
- Azure Functions: Auto-scale based on Event Hub partition load
- ACI: Each scan runs in isolated container, unlimited parallel scans

## Security

- **Managed Identity**: Function app uses managed identity for Azure API access
- **Key Vault**: Qualys credentials stored in Azure Key Vault
- **Network Isolation**: Scanner containers run in isolated ACI instances
- **No persistence**: Containers are ephemeral, no data persists after scan

## Configuration

### Required Environment Variables
```
QUALYS_POD=US2
QUALYS_ACCESS_TOKEN=<token or KeyVault reference>
AZURE_SUBSCRIPTION_ID=<subscription-id>
STORAGE_CONNECTION_STRING=<storage-connection-string>
EVENTHUB_CONNECTION_STRING=<eventhub-connection-string>
SCANNER_RESOURCE_GROUP=qualys-scanner-rg
QSCANNER_VERSION=4.6.0-4
```

### Optional Configuration
```
SCAN_TIMEOUT=1800
SCAN_CACHE_HOURS=24
QSCANNER_IMAGE=docker:24.0-dind
NOTIFICATION_EMAIL=<email for alerts>
NOTIFY_SEVERITY_THRESHOLD=HIGH
```

## Monitoring

- **Application Insights**: Function execution logs, scan results, errors
- **Activity Log**: ACI container lifecycle events
- **Storage Metrics**: Scan result volume, cache hit rate

## Limitations

1. **Activity Log Latency**: 10-15 minute delay from deployment to scan (longer than documented 2-5 min)
2. **ACI Limits**: Regional quotas, resource limits (4 CPU / 16 GB per container group)
3. **Docker-in-Docker overhead**: Additional resource usage and startup time
4. **Public images only**: Currently scans public registry images (ACR support requires authentication)

## Future Enhancements

- [ ] Azure Container Registry (ACR) authentication
- [ ] Private registry support
- [ ] Async scanning with status webhooks
- [ ] Custom scan policies
- [ ] Multi-region deployment
- [ ] Scan result aggregation dashboard
