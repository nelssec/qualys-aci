# qscanner Setup Guide

This guide explains how to set up and deploy qscanner for scanning container images in ACI/ACA.

## What is qscanner?

qscanner is Qualys's command-line scanner that can scan:
- Docker images using `--image` flag
- Local code repositories using `--repo` flag
- Remote repositories using `--repo` with URLs

For our use case, we use qscanner to scan container images deployed to Azure Container Instances and Azure Container Apps.

## Deployment Options

You have three options for deploying qscanner:

### Option 1: qscanner in Azure Container Instance (Recommended)

Deploy qscanner as a container instance that can be invoked by the Azure Function.

**Pros:**
- Serverless, scales to zero when not in use
- Easy deployment with Bicep template
- No VM management overhead
- Cost-effective for low-to-medium scan volumes

**Cons:**
- Cold start time for first scan
- Limited to qscanner's container scanning capabilities

**Deployment:**
```bash
cd infrastructure

# Deploy qscanner container
az deployment group create \
  --resource-group qualys-scanner-rg \
  --template-file qscanner-deployment.bicep \
  --parameters \
    qscannerName="qscanner-instance" \
    qualysUsername="$QUALYS_USERNAME" \
    qualysPassword="$QUALYS_PASSWORD" \
    cpuCores=2 \
    memoryInGb=4
```

### Option 2: qscanner on Azure VM

Deploy qscanner on a dedicated VM with Docker installed.

**Pros:**
- Always warm, no cold start
- Can run multiple concurrent scans
- Full control over Docker environment
- Better for high scan volumes

**Cons:**
- Always-on cost (even when idle)
- Requires VM management
- Need to handle updates and patches

**Deployment:**
```bash
cd infrastructure
chmod +x qscanner-vm-deployment.sh

./qscanner-vm-deployment.sh \
  -r qualys-scanner-rg \
  -l eastus \
  -u "$QUALYS_USERNAME" \
  -p "$QUALYS_PASSWORD"
```

### Option 3: qscanner in Function App Container

Install qscanner directly in the Function App container (custom container deployment).

**Pros:**
- No separate infrastructure needed
- Lowest latency (same container as function)
- Simplest network configuration

**Cons:**
- Larger function container image
- qscanner updates require function redeployment
- Docker socket access challenges

**Setup:**
Create custom Dockerfile for function:

```dockerfile
FROM mcr.microsoft.com/azure-functions/python:4-python3.11

# Install Docker CLI (for qscanner)
RUN apt-get update && \
    apt-get install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg && \
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null && \
    apt-get update && \
    apt-get install -y docker-ce-cli

# Download qscanner
RUN curl -o /usr/local/bin/qscanner https://qualysguard.qg2.apps.qualys.com/csdownload/qscanner && \
    chmod +x /usr/local/bin/qscanner

# Copy function code
COPY . /home/site/wwwroot

# Install Python dependencies
RUN pip install --no-cache-dir -r /home/site/wwwroot/requirements.txt
```

## qscanner Configuration

### Environment Variables

Configure these in your Function App or qscanner host:

| Variable | Description | Required |
|----------|-------------|----------|
| `QUALYS_USERNAME` | Qualys account username | Yes |
| `QUALYS_PASSWORD` | Qualys account password | Yes |
| `QSCANNER_PATH` | Path to qscanner binary | No (default: /usr/local/bin/qscanner) |
| `SEVERITY_THRESHOLD` | Minimum severity to report (CRITICAL, HIGH, MEDIUM, LOW) | No (default: MEDIUM) |
| `SCAN_TIMEOUT` | Maximum scan duration in seconds | No (default: 1800) |

### qscanner Command Examples

Scan a public Docker image:
```bash
qscanner --image nginx:latest --tag deployment=aci --tag env=prod
```

Scan a private Azure Container Registry image:
```bash
# First, authenticate to ACR
az acr login --name myacr

# Then scan
qscanner --image myacr.azurecr.io/myapp:v1.0 --tag deployment=aca --tag resource_group=prod-rg
```

Scan with specific output format:
```bash
qscanner --image nginx:latest \
  --output-format json \
  --output-file scan-results.json \
  --tag image=nginx:latest \
  --tag scan_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
```

## How the Integration Works

### Event Flow with qscanner

```
1. Container deployed to ACI/ACA
   ↓
2. Event Grid captures deployment event
   ↓
3. Azure Function receives event
   ↓
4. Function extracts image name (e.g., "nginx:latest")
   ↓
5. Function builds qscanner command:
   qscanner --image nginx:latest \
     --tag container_type=ACI \
     --tag image=nginx:latest \
     --tag scan_time=2024-01-15T10:30:00Z \
     --tag resource_group=prod-rg \
     --output-format json
   ↓
6. qscanner pulls and scans the image
   ↓
7. qscanner returns JSON with vulnerabilities
   ↓
8. Function parses JSON results
   ↓
9. Function stores results in Azure Storage
   ↓
10. Function sends alert if high-severity vulns found
```

### Custom Tags for Tracking

The function automatically adds tags to each qscanner scan:

- `image`: Full image name (e.g., docker.io/library/nginx:latest)
- `container_type`: ACI or ACA
- `scan_time`: ISO 8601 timestamp
- `azure_subscription`: Subscription ID
- `resource_group`: Resource group name
- `event_id`: Event Grid event ID

These tags allow you to:
- Correlate scans with specific deployments
- Track scan history per resource group
- Filter scans by container type
- Identify which subscription triggered the scan

### Qualys Tag Query

You can query scans in Qualys portal using these tags:

```
In Qualys Console → Container Security → Scans:
- Filter by tag: container_type=ACI
- Filter by tag: resource_group=production-rg
- Filter by tag: image=myapp:v1.0
```

## Scanning Private Registries

### Azure Container Registry (ACR)

qscanner needs to authenticate to private registries before scanning.

**Option A: Managed Identity (Recommended)**

Grant the qscanner VM/container AcrPull role:

```bash
# Get qscanner VM principal ID
SCANNER_PRINCIPAL_ID=$(az vm identity show \
  --resource-group qualys-scanner-rg \
  --name qscanner-vm \
  --query principalId -o tsv)

# Grant ACR pull access
az role assignment create \
  --assignee $SCANNER_PRINCIPAL_ID \
  --role "AcrPull" \
  --scope "/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.ContainerRegistry/registries/<acr-name>"

# Function will handle ACR auth before scanning
```

**Option B: Service Principal**

Create service principal with ACR access:

```bash
# Create service principal
SP_JSON=$(az ad sp create-for-rbac --name qscanner-sp --skip-assignment)
SP_ID=$(echo $SP_JSON | jq -r '.appId')
SP_PASSWORD=$(echo $SP_JSON | jq -r '.password')

# Grant ACR pull
az role assignment create \
  --assignee $SP_ID \
  --role "AcrPull" \
  --scope "/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.ContainerRegistry/registries/<acr-name>"

# Configure in function
az functionapp config appsettings set \
  --name $FUNCTION_APP_NAME \
  --resource-group qualys-scanner-rg \
  --settings \
    "ACR_SERVICE_PRINCIPAL_ID=$SP_ID" \
    "ACR_SERVICE_PRINCIPAL_PASSWORD=$SP_PASSWORD"
```

**Option C: Admin Credentials**

```bash
# Enable admin user (not recommended for production)
az acr update --name myacr --admin-enabled true

# Get credentials
ACR_USERNAME=$(az acr credential show --name myacr --query username -o tsv)
ACR_PASSWORD=$(az acr credential show --name myacr --query "passwords[0].value" -o tsv)

# Docker login before scan
docker login myacr.azurecr.io -u $ACR_USERNAME -p $ACR_PASSWORD

# Then scan
qscanner --image myacr.azurecr.io/app:v1.0
```

## Troubleshooting

### qscanner not found

```bash
# Verify qscanner installation
which qscanner
/usr/local/bin/qscanner

# Check version
qscanner --version

# If not found, download from Qualys
wget -O /usr/local/bin/qscanner https://qualysguard.qg2.apps.qualys.com/csdownload/qscanner
chmod +x /usr/local/bin/qscanner
```

### Authentication errors

```bash
# Test qscanner auth
qscanner --image alpine:latest

# If auth fails, verify credentials
echo $QUALYS_USERNAME
echo $QUALYS_PASSWORD  # Ensure password is set

# Try explicit auth
qscanner --username $QUALYS_USERNAME --password $QUALYS_PASSWORD --image alpine:latest
```

### Image pull errors

```bash
# Verify Docker is running
docker ps

# Test image pull manually
docker pull nginx:latest

# For ACR images, verify authentication
az acr login --name myacr
docker pull myacr.azurecr.io/myapp:v1.0
```

### Scan timeout

```bash
# Increase timeout in function app settings
az functionapp config appsettings set \
  --name $FUNCTION_APP_NAME \
  --resource-group qualys-scanner-rg \
  --settings "SCAN_TIMEOUT=3600"  # 1 hour

# Also increase function timeout in host.json
{
  "functionTimeout": "00:30:00"  # 30 minutes
}
```

### JSON parsing errors

```bash
# Run qscanner manually and check output format
qscanner --image nginx:latest --output-format json --output-file /tmp/scan.json

# Verify JSON is valid
cat /tmp/scan.json | jq .

# Check qscanner version (older versions may have different JSON format)
qscanner --version
```

## Performance Optimization

### Caching Images

Pre-pull frequently scanned images on qscanner host:

```bash
# Pre-pull common base images
docker pull nginx:latest
docker pull alpine:latest
docker pull ubuntu:latest
docker pull mcr.microsoft.com/dotnet/runtime:6.0

# This reduces scan time significantly
```

### Parallel Scans

Configure multiple qscanner instances for parallel scanning:

```bash
# Create multiple qscanner VMs
for i in {1..3}; do
  ./qscanner-vm-deployment.sh \
    -r qualys-scanner-rg \
    -l eastus \
    -n "qscanner-vm-$i"
done

# Load balance scans across instances
# (requires custom load balancing logic in function)
```

### Resource Sizing

Recommended VM sizes for different scan volumes:

| Scan Volume | VM Size | CPU | Memory | Cost/Month |
|-------------|---------|-----|--------|------------|
| <10/day | B2s | 2 | 4 GB | ~$30 |
| 10-50/day | D2s_v3 | 2 | 8 GB | ~$70 |
| 50-200/day | D4s_v3 | 4 | 16 GB | ~$140 |
| >200/day | D8s_v3 | 8 | 32 GB | ~$280 |

## Security Best Practices

1. **Store credentials in Key Vault** (already configured)
2. **Use Managed Identity** for ACR access
3. **Deploy in private VNet** for production
4. **Enable NSG rules** to restrict qscanner access
5. **Rotate Qualys credentials** regularly
6. **Enable Azure Defender** for additional protection
7. **Use Private Endpoints** for storage and Key Vault
8. **Enable audit logging** for all scan activities

## Advanced Configuration

### Custom scan profiles

Create different scan configurations:

```bash
# High-security profile
qscanner --image myapp:latest \
  --severity-threshold CRITICAL \
  --tag profile=high-security

# Development profile
qscanner --image myapp:dev \
  --severity-threshold LOW \
  --tag profile=development
```

### Integration with CI/CD

Scan images before deployment:

```yaml
# Azure DevOps pipeline
- task: AzureCLI@2
  inputs:
    azureSubscription: 'MySubscription'
    scriptType: 'bash'
    scriptLocation: 'inlineScript'
    inlineScript: |
      # Build image
      docker build -t myacr.azurecr.io/app:$(Build.BuildId) .

      # Scan with qscanner
      qscanner --image myacr.azurecr.io/app:$(Build.BuildId) \
        --tag build_id=$(Build.BuildId) \
        --tag pipeline=$(Build.DefinitionName)

      # Push if scan passes
      docker push myacr.azurecr.io/app:$(Build.BuildId)
```

## Monitoring qscanner

Monitor qscanner performance and health:

```bash
# Check qscanner logs
journalctl -u docker -f | grep qscanner

# Monitor resource usage
top -p $(pgrep qscanner)

# Check scan history
ls -lh /var/log/qscanner/

# Query Azure Monitor for scan metrics
az monitor metrics list \
  --resource "/subscriptions/<sub-id>/resourceGroups/qualys-scanner-rg/providers/Microsoft.Compute/virtualMachines/qscanner-vm" \
  --metric "Percentage CPU"
```

## Cost Optimization

### Recommendations:

1. **Use ACI for qscanner** instead of always-on VM (save ~70%)
2. **Enable auto-shutdown** for qscanner VM during off-hours
3. **Use spot instances** for non-critical scanning (save ~90%)
4. **Implement scan caching** to avoid duplicate scans
5. **Pre-pull base images** to reduce scan time
6. **Use smaller VM** for low scan volumes

## Support

For qscanner-specific issues:
- Qualys Documentation: https://docs.qualys.com/en/qscanner/
- Qualys Support: https://www.qualys.com/support/
- qscanner Download: https://qualysguard.qg2.apps.qualys.com/csdownload/

For Azure integration issues:
- Check Application Insights logs
- Review function execution logs
- Verify Event Grid delivery metrics
