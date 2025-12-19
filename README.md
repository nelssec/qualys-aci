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
- Qualys API Token (Container Security permissions)
- Azure Functions Core Tools 4.x

## Quick Start

### Using Makefile (Recommended)

```bash
# Set your Qualys API token
export QUALYS_ACCESS_TOKEN='your-qualys-token'

# Deploy (auto-creates Service Principal for ACR access)
make deploy QUALYS_POD=CA1
```

The Makefile automatically:
- Creates a Service Principal with AcrPull role
- Deploys all Azure infrastructure via Bicep
- Publishes the Azure Function code

### Manual Deployment

```bash
# 1. Create Service Principal for ACR Access
az ad sp create-for-rbac \
  --name qualys-acr-scanner \
  --role AcrPull \
  --scopes /subscriptions/$(az account show --query id -o tsv)

# Save: appId → ACR_APPLICATION_ID, password → ACR_CLIENT_SECRET

# 2. Deploy
export QUALYS_API_TOKEN="your-qualys-token"
export ACR_APPLICATION_ID="your-service-principal-app-id"
export ACR_CLIENT_SECRET="your-service-principal-secret"

./deploy.sh
```

## Makefile Targets

| Target | Description |
|--------|-------------|
| `make deploy QUALYS_POD=CA1` | Deploy scanner (auto-creates SP) |
| `make status` | Show deployment status |
| `make logs` | Stream function app logs |
| `make test-scan TEST_IMAGE=...` | Deploy test container |
| `make cleanup` | Remove all resources |
| `make create-sp` | Manually create Service Principal |

## Configuration

| Variable | Description | Default |
|----------|-------------|---------|
| `QUALYS_ACCESS_TOKEN` | Qualys API Bearer token | Required |
| `QUALYS_POD` | Qualys POD (US1, US2, CA1, etc.) | Required |
| `RESOURCE_GROUP` | Azure resource group name | `qualys-scanner-rg` |
| `LOCATION` | Azure region | `eastus` |
| `SCAN_CACHE_HOURS` | Hours before rescanning same image | `24` |

### Qualys POD Gateway URLs

| POD | Gateway URL |
|-----|-------------|
| US1 | `https://gateway.qg1.apps.qualys.com` |
| US2 | `https://gateway.qg2.apps.qualys.com` |
| US3 | `https://gateway.qg3.apps.qualys.com` |
| EU1 | `https://gateway.qg1.apps.qualys.eu` |
| EU2 | `https://gateway.qg2.apps.qualys.eu` |
| CA1 | `https://gateway.qg1.apps.qualys.ca` |
| AU1 | `https://gateway.qg1.apps.qualys.com.au` |

### ACR Connector Naming

The ACR connector in Qualys is automatically named: `acr-{subscription_short}`

Example: `acr-d8ee7e92`

One connector covers all ACRs in the subscription (regardless of region).

## Multi-Subscription Deployment

Deploy to a central subscription and add spoke subscriptions:

```bash
export QUALYS_ACCESS_TOKEN="your-qualys-token"
export CENTRAL_SUBSCRIPTION_ID="your-central-subscription-id"

make deploy-multi QUALYS_POD=CA1

# Add spoke subscriptions
make add-spoke SPOKE_SUBSCRIPTION_ID="spoke-subscription-id"
```

## Testing

```bash
make test-scan TEST_IMAGE=myacr.azurecr.io/myapp:v1.0
```

Or manually:

```bash
az container create \
  --resource-group qualys-scanner-rg \
  --name test-scan-$(date +%s) \
  --image <your-acr>.azurecr.io/<repo>:<tag> \
  --os-type Linux \
  --cpu 1 --memory 1 \
  --restart-policy Never
```

**Note:** Only images from Azure Container Registry (`.azurecr.io`) are scanned. Public images are skipped.

## Notifications

Scan events are sent to Azure Service Bus queue `scan-notifications`. Subscribe to receive:
- `scan_submitted` - New scan initiated

## Project Structure

```
qualys-aci/
├── Makefile                 # Simplified deployment commands
├── function_app/
│   ├── function_app.py      # Azure Function (Event Hub trigger)
│   ├── qualys_api.py        # Qualys Registry API client
│   ├── image_parser.py      # Container image name parser
│   ├── storage_handler.py   # Azure Storage operations
│   └── requirements.txt     # Python 3.12 dependencies
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
| Storage Account | Storage Blob Data Contributor | Storage Account |
| Storage Account | Storage Table Data Contributor | Storage Account |
| Event Hub | Azure Event Hubs Data Receiver | Event Hub Namespace |
| Service Bus | Azure Service Bus Data Sender | Service Bus Namespace |
| Key Vault | Key Vault Secrets User | Key Vault |

### Custom Role for Minimal Permissions

Instead of the broad `Reader` role, a custom role grants only:
- `Microsoft.ContainerInstance/containerGroups/read`
- `Microsoft.App/containerApps/read`
- `Microsoft.Resources/subscriptions/resourceGroups/read`

### Disabled Legacy Authentication

- **Event Hub**: `disableLocalAuth: true` - No SAS token authentication
- **Service Bus**: `disableLocalAuth: true` - No SAS token authentication

### Secrets in Key Vault

Only two secrets stored in Key Vault (accessed via Key Vault references):
- Qualys API Token
- Service Principal Secret (for ACR connector)

## Technology Stack

- **Runtime**: Python 3.12
- **Infrastructure**: Azure Bicep (2024/2025 API versions)
- **Authentication**: Managed Identity + Service Principal

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
- ACR images only (public images are skipped)
- Service Principal must have access to all ACRs

## License

MIT License
