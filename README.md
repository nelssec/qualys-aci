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
| US4 | `https://gateway.qg4.apps.qualys.com` |
| GOV1 | `https://gateway.gov1.qualys.us` |
| EU1 | `https://gateway.qg1.apps.qualys.eu` |
| EU2 | `https://gateway.qg2.apps.qualys.eu` |
| EU3 | `https://gateway.qg3.apps.qualys.it` |
| IN1 | `https://gateway.qg1.apps.qualys.in` |
| CA1 | `https://gateway.qg1.apps.qualys.ca` |
| AE1 | `https://gateway.qg1.apps.qualys.ae` |
| UK1 | `https://gateway.qg1.apps.qualys.co.uk` |
| AU1 | `https://gateway.qg1.apps.qualys.com.au` |
| KSA1 | `https://gateway.qg1.apps.qualysksa.com` |

Identify the platform that hosts your subscription at [Qualys Platform Identification](https://www.qualys.com/platform-identification).

### ACR Connector Naming

The ACR connector in Qualys is automatically named: `acr-{subscription_short}`

Example: `acr-d8ee7e92`

One connector covers all ACRs in the subscription (regardless of region).

## Azure Government and Sovereign Clouds

The Bicep templates and function code are cloud-agnostic. Azure endpoints for
storage, Event Hub, Service Bus, Key Vault, Azure Container Registry, and Azure
Resource Manager are resolved at deploy time from the cloud the Azure CLI
targets, using the Bicep `environment()` function. The function app reads these
endpoints from its app settings. ACR images are recognized in each cloud:
`.azurecr.io` (Public), `.azurecr.us` (US Government), and `.azurecr.cn` (China).

The Qualys platform is independent of the Azure cloud. Set `QUALYS_POD` (or
`QUALYS_GATEWAY_URL`) to the platform that hosts your Qualys subscription. This
can be a commercial platform (US1 through US4, EU, CA1, and others) or the
Qualys Government platform (GOV1). Identify your platform at
[Qualys Platform Identification](https://www.qualys.com/platform-identification).

To deploy into Azure US Government:

```bash
# 1. Target the Azure Government cloud and sign in
az cloud set --name AzureUSGovernment
az login

# 2. Deploy to a Government region, using your Qualys platform
export QUALYS_ACCESS_TOKEN='your-qualys-token'
make deploy QUALYS_POD=GOV1 LOCATION=usgovvirginia
```

Notes:
- `LOCATION` defaults to `eastus`. Set a Government region such as
  `usgovvirginia` or `usgovtexas`.
- `QUALYS_POD` accepts any platform in the gateway table, including GOV1. For a
  platform not listed, set `QUALYS_GATEWAY_URL` directly. When
  `QUALYS_GATEWAY_URL` is set, `QUALYS_POD` is not required.
- Run `az cloud set --name AzureUSGovernment` before any deploy or cleanup
  command so the service principal and ARM deployments are created in the
  Government tenant.

## Private Networking

By default the Function's supporting resources (Storage, Key Vault, Event Hub,
Service Bus) are deployed with public network access, and the Function runs on
the Consumption plan. This is not required. Set `enablePrivateNetworking=true`
to VNet-integrate the Function, add private endpoints, and disable public access
on those resources.

When enabled, the deployment:
- Runs the Function on an Elastic Premium plan (Consumption cannot VNet-integrate;
  a `Y1` selection is upgraded to `EP1`).
- Provisions Event Hub and Service Bus at the Standard tier (Basic does not
  support private endpoints).
- Regional VNet-integrates the Function into `functionSubnetId` and routes all
  outbound traffic through the VNet.
- Creates private endpoints for Storage (blob, file, queue, table), Key Vault,
  Event Hub, and Service Bus in `privateEndpointSubnetId`.
- Sets public network access to Disabled on Storage, Key Vault, Event Hub, and
  Service Bus.

Bring your own subnets and use your existing private DNS:

```bash
export ENABLE_PRIVATE_NETWORKING=true
export FUNCTION_SUBNET_ID='/subscriptions/.../subnets/functions'          # delegated to Microsoft.Web/serverFarms
export PRIVATE_ENDPOINT_SUBNET_ID='/subscriptions/.../subnets/endpoints'

make deploy QUALYS_POD=US2
```

DNS resolution for the private endpoints is left to your central resolver or
Azure Policy by default. To have the template register records in existing
zones, pass `privateDnsZoneIds` (via `main.bicepparam` or a direct
`az deployment` call), keyed by sub-resource:

```bicep
param privateDnsZoneIds = {
  blob: '/subscriptions/.../privateDnsZones/privatelink.blob.core.windows.net'
  file: '/subscriptions/.../privateDnsZones/privatelink.file.core.windows.net'
  queue: '/subscriptions/.../privateDnsZones/privatelink.queue.core.windows.net'
  table: '/subscriptions/.../privateDnsZones/privatelink.table.core.windows.net'
  vault: '/subscriptions/.../privateDnsZones/privatelink.vaultcore.azure.net'
  servicebus: '/subscriptions/.../privateDnsZones/privatelink.servicebus.windows.net'
}
```

Notes:
- Zone names are cloud-specific. In Azure Government use the
  `privatelink.*.usgovcloudapi.net` equivalents.
- The Function reads ACI/ACA container definitions through Azure Resource
  Manager (control plane), so scanning private ACA/ACR deployments does not
  require the app to reach their data plane.
- Scanning by Qualys Cloud Platform still requires the registry to be reachable
  from Qualys. A registry with no path from Qualys needs the Qualys Registry
  Sensor deployed inside your network; that sensor is not part of this template.
- Application Insights ingestion remains public unless you front it with Azure
  Monitor Private Link Scope (AMPLS), which is out of scope here.

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
