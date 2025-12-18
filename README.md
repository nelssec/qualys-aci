# Qualys Container Scanner for Azure ACI/ACA

Event-driven vulnerability scanning for Azure Container Instances (ACI) and Azure Container Apps (ACA) using the Qualys Container Security Registry API.

## Architecture

```
ACI/ACA Deployment → Activity Log → Event Hub → Azure Function → Qualys Registry API
                                                      ↓
                                                Check Cache
                                                      ↓
                                         Get/Create ACR Registry
                                                      ↓
                                           Submit On-Demand Scan
                                                      ↓
                                            Qualys Cloud Platform
```

**How it works:**
1. Container deployed to ACI or ACA
2. Activity Log captures the deployment event (~10-15 min latency)
3. Event streams to Event Hub via diagnostic settings
4. Azure Function processes the event
5. Function checks 24-hour scan cache
6. If not cached, creates ACR registry in Qualys (if needed)
7. Submits on-demand scan request to Qualys
8. Qualys pulls image from ACR using Service Principal
9. Scan results appear in Qualys Cloud Platform

## Prerequisites

- Azure CLI 2.50+
- Azure subscription with Contributor role
- Qualys subscription with Container Security module
- Qualys API Token
- Azure Functions Core Tools 4.x (for deployment)

## Quick Start

### 1. Create Service Principal for ACR Access

Qualys needs a Service Principal to pull images from your ACR registries:

```bash
# Create Service Principal with AcrPull role at subscription level
az ad sp create-for-rbac \
  --name qualys-acr-scanner \
  --role AcrPull \
  --scopes /subscriptions/$(az account show --query id -o tsv)
```

Save the output - you'll need:
- `appId` → `ACR_APPLICATION_ID`
- `password` → `ACR_CLIENT_SECRET`

### 2. Get Qualys API Token

1. Login to Qualys Cloud Platform
2. Navigate to **Administration** → **API Tokens**
3. Generate a new token with Container Security permissions

### 3. Deploy

```bash
export QUALYS_API_TOKEN="your-qualys-token"
export ACR_APPLICATION_ID="your-service-principal-app-id"
export ACR_CLIENT_SECRET="your-service-principal-secret"

# Optional: customize gateway URL for your Qualys POD
export QUALYS_GATEWAY_URL="https://gateway.qg2.apps.qualys.com"

./deploy.sh
```

## Configuration

| Environment Variable | Description | Default |
|---------------------|-------------|---------|
| `QUALYS_GATEWAY_URL` | Qualys API gateway URL | `https://gateway.qg2.apps.qualys.com` |
| `QUALYS_API_TOKEN` | Qualys API Bearer token | Required |
| `ACR_CONNECTOR_NAME` | Name for ACR connector in Qualys | `qualys-aci-connector` |
| `ACR_APPLICATION_ID` | Service Principal App ID | Required |
| `ACR_CLIENT_SECRET` | Service Principal Secret | Required |
| `SCAN_CACHE_HOURS` | Hours before rescanning same image | `24` |

### Qualys Gateway URLs by POD

| POD | Gateway URL |
|-----|-------------|
| US1 | `https://gateway.qg1.apps.qualys.com` |
| US2 | `https://gateway.qg2.apps.qualys.com` |
| US3 | `https://gateway.qg3.apps.qualys.com` |
| US4 | `https://gateway.qg4.apps.qualys.com` |
| EU1 | `https://gateway.qg1.apps.qualys.eu` |
| EU2 | `https://gateway.qg2.apps.qualys.eu` |
| CA1 | `https://gateway.qg1.apps.qualys.ca` |
| AE1 | `https://gateway.qg1.apps.qualys.ae` |
| AU1 | `https://gateway.qg1.apps.qualys.com.au` |
| IN1 | `https://gateway.qg1.apps.qualys.in` |

## Testing

Deploy a test container from ACR:

```bash
# Deploy container from your ACR
az container create \
  --resource-group qualys-scanner-rg \
  --name test-scan-$(date +%s) \
  --image <your-acr>.azurecr.io/<repo>:<tag> \
  --os-type Linux \
  --cpu 1 --memory 1 \
  --restart-policy Never

# Monitor function logs
func azure functionapp logstream $(az functionapp list -g qualys-scanner-rg --query "[0].name" -o tsv)
```

**Note:** Only images from Azure Container Registry (`.azurecr.io`) are scanned. Public images (Docker Hub, MCR) are skipped.

## Viewing Results

1. Login to Qualys Cloud Platform
2. Navigate to **Container Security** → **Images**
3. Find your scanned images

Results typically appear 5-10 minutes after scan submission.

## How Scanning Works

1. **Event Detection**: Activity Log captures ACI/ACA create/update events
2. **Image Discovery**: Function fetches container images from Azure Management API
3. **Registry Setup**: Creates ACR connector and registry in Qualys (first time only)
4. **Scan Submission**: Submits on-demand scan to Qualys Registry API
5. **Image Pull**: Qualys pulls image from ACR using Service Principal credentials
6. **Vulnerability Analysis**: Qualys scans for OS packages, SCA, and secrets
7. **Results**: Available in Qualys Cloud Platform

## Troubleshooting

### Scans Not Triggering

Check Activity Log diagnostic settings:
```bash
az monitor diagnostic-settings subscription list \
  --query "value[?name=='activity-log-to-eventhub']"
```

Check function logs:
```bash
az monitor app-insights query \
  --app $(az monitor app-insights component list -g qualys-scanner-rg --query "[0].appId" -o tsv) \
  --analytics-query "traces | where timestamp > ago(1h) | project timestamp, message | order by timestamp desc" \
  --offset 1h
```

### ACR Authentication Issues

Verify Service Principal has AcrPull role:
```bash
az role assignment list \
  --assignee $ACR_APPLICATION_ID \
  --query "[?roleDefinitionName=='AcrPull'].{Scope:scope}"
```

### Registry Not Found in Qualys

The function auto-creates ACR registries in Qualys. Check function logs for errors:
```bash
func azure functionapp logstream <function-app-name>
```

### Force Rescan

Delete the cache entry in Table Storage:
```bash
STORAGE=$(az storage account list -g qualys-scanner-rg --query "[0].name" -o tsv)
az storage entity delete \
  --account-name $STORAGE \
  --table-name ScanMetadata \
  --partition-key <registry_repo> \
  --row-key <scan_id>
```

## Security

### RBAC Roles

| Principal | Role | Scope | Purpose |
|-----------|------|-------|---------|
| Function App | Reader | Subscription | Read ACI/ACA metadata |
| Function App | Key Vault Secrets User | Key Vault | Access secrets |
| Service Principal | AcrPull | Subscription or ACR | Qualys pulls images |

### Secrets Management

- Qualys API Token: Stored in Key Vault
- Service Principal Secret: Stored in Key Vault
- Both accessed via Key Vault references in Function App settings

## Cost Estimate

Monthly cost (moderate usage, ~100 scans):

| Service | SKU | Cost |
|---------|-----|------|
| Azure Functions | Consumption | $3-8 |
| Storage Account | Standard LRS | $1-2 |
| Event Hub | Basic | $11 |
| Application Insights | Pay-as-you-go | $0-2 |
| **Total** | | **~$15-23/month** |

## Project Structure

```
qualys-aci/
├── function_app/
│   ├── function_app.py      # Azure Function (Event Hub trigger)
│   ├── qualys_api.py        # Qualys Registry API client
│   ├── image_parser.py      # Container image name parser
│   ├── storage_handler.py   # Azure Storage operations (cache)
│   ├── host.json            # Function configuration
│   └── requirements.txt     # Python dependencies
├── infrastructure/
│   ├── main.bicep           # Subscription-level deployment
│   ├── resources.bicep      # Resource group resources
│   └── main.bicepparam      # Parameter file
├── deploy.sh                # Deployment script
├── cleanup.sh               # Resource cleanup
└── README.md
```

## Limitations

- **Activity Log Latency**: 10-15 minutes from deployment to scan (Azure limitation)
- **ACR Only**: Only scans images from Azure Container Registry
- **Private Registries**: Service Principal must have access to all ACRs

## License

MIT License
