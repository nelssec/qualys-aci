# Using qualys/qscanner Docker Image

This document explains the updated architecture that uses the official **`qualys/qscanner` Docker image** for scanning.

## Why Use the Docker Image?

✅ **Better than VM approach:**
- Official Qualys image, always up-to-date
- No manual qscanner installation or updates needed
- Serverless - only pay when scanning (~$0.001 per scan)
- No VM management overhead
- Automatic scaling built-in

❌ **VM drawbacks:**
- Always-on cost (~$50-100/month even when idle)
- Manual updates and patching required
- Infrastructure management complexity

## Architecture Overview

### On-Demand ACI Scanner (Implemented)

```
Container deployed to ACI/ACA
    ↓
Event Grid captures deployment
    ↓
Azure Function receives event
    ↓
Function creates temporary ACI with qualys/qscanner image
    ↓
qscanner container pulls and scans the target image
    ↓
Function retrieves scan results from container logs
    ↓
Function stores results in Azure Storage
    ↓
ACI container automatically deleted
    ↓
Cost: ~$0.001 per scan (2 GB RAM, 1 CPU, ~2 min runtime)
```

### How It Works

1. **Event Trigger**: Container deployment event arrives
2. **ACI Creation**: Function creates a container instance:
   ```bash
   Image: qualys/qscanner:latest
   Command: qscanner --image nginx:latest --tag deployment=aci --output-format json
   Environment: QUALYS_USERNAME, QUALYS_PASSWORD
   ```
3. **Scanning**: qscanner container:
   - Authenticates to Qualys
   - Pulls the target image (nginx:latest)
   - Scans for vulnerabilities
   - Outputs JSON results to logs
4. **Results**: Function reads container logs to get scan results
5. **Cleanup**: Container instance deleted (no ongoing cost)

## Implementation Details

### Code Structure

- **`qualys_scanner_aci.py`**: ACI-based scanner implementation
  - Uses Azure Container Instances Management SDK
  - Creates/monitors/deletes ACI containers on-demand
  - Parses qscanner JSON output from container logs

- **`EventProcessor/__init__.py`**: Updated to use ACI scanner
  ```python
  scanner = QScannerACI()
  scan_result = scanner.scan_image(...)
  ```

### Required Permissions

The Function App's Managed Identity needs:
- **Contributor role** on the resource group (to create/delete ACI)
- **Key Vault Secrets User** role (for Qualys credentials)

These are automatically configured in the Bicep template.

### Configuration

Environment variables (set in Bicep template):
```bash
AZURE_SUBSCRIPTION_ID=<subscription-id>
QSCANNER_RESOURCE_GROUP=<rg-name>      # Where to create scan containers
AZURE_REGION=eastus                     # Region for scan containers
QSCANNER_IMAGE=qualys/qscanner:latest   # Docker image to use
QUALYS_USERNAME=<from-key-vault>
QUALYS_PASSWORD=<from-key-vault>
```

## Cost Analysis

### Using qualys/qscanner Docker Image in ACI

**Per-scan cost:**
- 1 CPU, 2 GB RAM
- Average scan duration: 2 minutes
- Cost: 2 min × ($0.000012/sec for 1 CPU + $0.000001/sec per GB) ≈ **$0.001 per scan**

**Monthly costs (100 scans/day):**
- Scan costs: 100 × 30 × $0.001 = **$3/month**
- Function App (Consumption): **$2/month**
- Storage: **$2/month**
- **Total: ~$7/month**

### Using VM with qscanner

**Monthly costs:**
- Standard_D2s_v3 VM (2 CPU, 8 GB): **$70/month** (always on)
- Storage: **$10/month**
- **Total: ~$80/month**

**Savings: ~$73/month (91% cheaper with Docker image approach!)**

## Deployment

### Quick Start

```bash
cd infrastructure

# Deploy with Docker image approach (default)
./deploy.sh \
  -s "your-subscription-id" \
  -r "qualys-scanner-rg" \
  -l "eastus" \
  -n "$QUALYS_USERNAME" \
  -w "$QUALYS_PASSWORD" \
  --deploy-function
```

That's it! No need to deploy VMs or install qscanner manually.

### Verify Deployment

```bash
# Deploy a test container
az container create \
  --resource-group test-rg \
  --name test-nginx \
  --image nginx:latest

# Check for temporary scan container (will be deleted after scan)
az container list \
  --resource-group qualys-scanner-rg \
  --query "[?starts_with(name, 'qscanner-')].{Name:name, State:instanceView.state}" \
  --output table

# View scan results
az monitor app-insights query \
  --app <function-app-name> \
  --analytics-query "traces | where message contains 'Scanning image' | order by timestamp desc"
```

## How qscanner Scans Images

The qscanner Docker container can scan images in several ways:

### 1. Public Images
```bash
qscanner --image nginx:latest
```
qscanner pulls from Docker Hub and scans

### 2. Azure Container Registry (ACR) Images

The ACI container automatically gets Managed Identity access to ACR:

```python
# Function authenticates to ACR before creating scan container
from azure.identity import DefaultAzureCredential
from azure.containerregistry import ContainerRegistryClient

# Get ACR access token
credential = DefaultAzureCredential()
# Pass credentials to qscanner container
```

Alternatively, grant the Function App's Managed Identity the **AcrPull** role:

```bash
az role assignment create \
  --assignee <function-app-principal-id> \
  --role "AcrPull" \
  --scope "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.ContainerRegistry/registries/<acr>"
```

### 3. Image Scanning Process

qscanner uses Docker API to:
1. Pull the image layers
2. Extract filesystem
3. Analyze packages and dependencies
4. Check against Qualys vulnerability database
5. Generate compliance reports
6. Output JSON results

No Docker daemon needed in the scan container - qscanner has built-in image handling.

## Advantages of This Approach

### 1. Cost Efficiency
- **91% cheaper** than VM approach
- Pay only for actual scan time
- No idle costs

### 2. Simplicity
- No VM management
- No qscanner installation/updates
- Official Docker image always current

### 3. Scalability
- Automatic horizontal scaling
- No resource contention
- Unlimited concurrent scans (within Azure limits)

### 4. Security
- Containers are ephemeral (deleted after scan)
- No long-running infrastructure to secure
- Credentials only in memory during scan
- Managed Identity for authentication

### 5. Reliability
- Fresh container for each scan
- No state/cache issues
- Automatic cleanup on failure

## Monitoring

### View Active Scans

```bash
# List running qscanner containers
az container list \
  --resource-group qualys-scanner-rg \
  --query "[?tags.purpose=='qscanner'].{Name:name, Image:containers[0].image, State:instanceView.state}"
```

### View Scan Logs

```bash
# Get logs from a scan container (while it's running)
az container logs \
  --resource-group qualys-scanner-rg \
  --name qscanner-nginx-latest-20240115123456
```

### Track Costs

```bash
# View ACI costs
az consumption usage list \
  --start-date 2024-01-01 \
  --end-date 2024-01-31 \
  --query "[?contains(instanceName, 'qscanner')].{Name:instanceName, Cost:pretaxCost}"
```

## Troubleshooting

### Scan Container Fails to Start

**Check Function App logs:**
```bash
az monitor app-insights query \
  --app <function-app-name> \
  --analytics-query "exceptions | where timestamp > ago(1h) | where customDimensions.Component == 'QScannerACI'"
```

**Common issues:**
- Insufficient quota (increase ACI quota in subscription)
- Invalid Qualys credentials (check Key Vault secrets)
- Network issues (check NSG rules if using VNet)

### Scan Times Out

**Increase timeout:**
```bash
az functionapp config appsettings set \
  --name <function-app-name> \
  --resource-group qualys-scanner-rg \
  --settings "SCAN_TIMEOUT=3600"  # 1 hour
```

### Cannot Access Private Registry

**Grant AcrPull role:**
```bash
# Get Function App identity
PRINCIPAL_ID=$(az functionapp identity show \
  --name <function-app-name> \
  --resource-group qualys-scanner-rg \
  --query principalId -o tsv)

# Grant ACR access
az role assignment create \
  --assignee $PRINCIPAL_ID \
  --role "AcrPull" \
  --scope "<acr-resource-id>"
```

## Comparison: VM vs Docker Image

| Feature | qualys/qscanner Docker | VM with qscanner |
|---------|------------------------|------------------|
| **Cost (100 scans/day)** | ~$7/month | ~$80/month |
| **Setup Complexity** | Low (just deploy) | High (install, configure) |
| **Maintenance** | None (auto-updated) | High (patches, updates) |
| **Cold Start** | ~15 seconds | 0 seconds (always on) |
| **Scalability** | Unlimited (auto-scale) | Limited (VM capacity) |
| **Security** | Ephemeral (no persistence) | Requires hardening |
| **Updates** | Automatic (Docker image) | Manual (apt/yum) |

## Conclusion

The **qualys/qscanner Docker image approach is the recommended solution** for this use case:

✅ 91% cost savings
✅ Zero maintenance
✅ Automatic scaling
✅ Built-in security
✅ Official Qualys support

The VM approach is only recommended for:
- Very high scan volumes (>1000/day) where cold start matters
- Air-gapped environments without internet access
- Custom qscanner configurations not available in Docker image

For most production workloads, use the Docker image approach implemented in this repository.
