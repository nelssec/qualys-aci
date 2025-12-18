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
                                           Service Bus Notification
                                                      ↓
                                            Qualys Cloud Platform
```

## Prerequisites

- Azure CLI 2.50+
- Azure subscription with Contributor role
- Qualys subscription with Container Security module
- Qualys API Token
- Azure Functions Core Tools 4.x

## Quick Start

### 1. Create Service Principal for ACR Access

```bash
az ad sp create-for-rbac \
  --name qualys-acr-scanner \
  --role AcrPull \
  --scopes /subscriptions/$(az account show --query id -o tsv)
```

Save the output:
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

./deploy.sh
```

## Configuration

| Variable | Description | Default |
|----------|-------------|---------|
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
| EU1 | `https://gateway.qg1.apps.qualys.eu` |
| EU2 | `https://gateway.qg2.apps.qualys.eu` |
| CA1 | `https://gateway.qg1.apps.qualys.ca` |
| AU1 | `https://gateway.qg1.apps.qualys.com.au` |

## Multi-Subscription Deployment

Deploy to a central subscription and add spoke subscriptions:

```bash
export QUALYS_API_TOKEN="your-qualys-token"
export ACR_APPLICATION_ID="your-service-principal-app-id"
export ACR_CLIENT_SECRET="your-service-principal-secret"
export CENTRAL_SUBSCRIPTION_ID="your-central-subscription-id"

./deploy-multi.sh

# Add spoke subscriptions
export SPOKE_SUBSCRIPTION_ID="spoke-subscription-id"
./add-spoke.sh
```

## Testing

```bash
az container create \
  --resource-group qualys-scanner-rg \
  --name test-scan-$(date +%s) \
  --image <your-acr>.azurecr.io/<repo>:<tag> \
  --os-type Linux \
  --cpu 1 --memory 1 \
  --restart-policy Never
```

Only images from Azure Container Registry (`.azurecr.io`) are scanned.

## Notifications

Scan events are sent to Azure Service Bus queue `scan-notifications`. Subscribe to receive:
- `scan_submitted` - New scan initiated

## Project Structure

```
qualys-aci/
├── function_app/
│   ├── function_app.py      # Azure Function (Event Hub trigger)
│   ├── qualys_api.py        # Qualys Registry API client
│   ├── image_parser.py      # Container image name parser
│   ├── storage_handler.py   # Azure Storage operations
│   └── requirements.txt
├── infrastructure/
│   ├── main.bicep           # Single subscription deployment
│   ├── central.bicep        # Multi-subscription central hub
│   ├── spoke.bicep          # Multi-subscription spoke
│   └── resources.bicep      # Core resources
├── deploy.sh                # Single subscription deployment
├── deploy-multi.sh          # Multi-subscription deployment
├── add-spoke.sh             # Add spoke subscription
└── cleanup.sh               # Resource cleanup
```

## Security

This solution follows Azure security best practices with least-privilege access:

### Managed Identity (No Connection Strings)

All Azure services use Managed Identity with RBAC instead of connection strings:

| Resource | Role | Scope |
|----------|------|-------|
| Storage Account | Storage Blob Data Owner | Storage Account |
| Storage Account | Storage Table Data Contributor | Storage Account |
| Event Hub | Azure Event Hubs Data Receiver | Event Hub Namespace |
| Service Bus | Azure Service Bus Data Sender | Service Bus Namespace |
| Key Vault | Key Vault Secrets User | Key Vault |

### Custom Role for Minimal Permissions

Instead of the broad `Reader` role, a custom role grants only:
- `Microsoft.ContainerInstance/containerGroups/read`
- `Microsoft.App/containerApps/read`
- `Microsoft.Resources/subscriptions/resourceGroups/read`

### Disabled Features

- **Storage**: `allowSharedKeyAccess: false` - No access key authentication
- **Event Hub**: `disableLocalAuth: true` - No SAS token authentication
- **Service Bus**: `disableLocalAuth: true` - No SAS token authentication

### Secrets in Key Vault

Only two secrets stored in Key Vault (accessed via Key Vault references):
- Qualys API Token
- Service Principal Secret (for ACR connector)

## Cost Estimate

Monthly (~100 scans):

| Service | Cost |
|---------|------|
| Azure Functions (Consumption) | $3-8 |
| Storage Account | $1-2 |
| Event Hub (Basic) | $11 |
| Service Bus (Basic) | $0.05 |
| Application Insights | $0-2 |
| **Total** | **~$15-25/month** |

## Limitations

- Activity Log latency: 10-15 minutes
- ACR images only
- Service Principal must have access to all ACRs

## License

MIT License
