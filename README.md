# Qualys Azure Container Scanning for ACI/ACA

Automated container image scanning solution for Azure Container Instances (ACI) and Azure Container Apps (ACA) using Qualys.

## Architecture Overview

This solution uses an event-driven architecture to automatically scan container images when they're deployed:

```
Azure ACI/ACA Deployment
    ↓
Azure Event Grid (captures deployment events)
    ↓
Azure Function (processes events)
    ↓
Qualys Scanner (scans container images)
    ↓
Results Storage & Logging
```

### Components

1. **Azure Event Grid Subscription**
   - Monitors Azure Resource Manager events
   - Filters for ACI and ACA container deployments
   - Routes events to Azure Function

2. **Azure Function App**
   - Receives deployment events
   - Extracts container image information
   - Triggers Qualys scans via API
   - Handles retries and error logging

3. **Qualys Integration**
   - Uses Qualys Container Security API
   - Supports both cloud-based and self-hosted qscanner
   - Stores scan results and compliance status

4. **Monitoring & Storage**
   - Application Insights for monitoring
   - Azure Storage for scan results
   - Alert configuration for failed scans

## Deployment Methods

### Method 1: Qualys Cloud API (Recommended)
Best for: Organizations using Qualys Cloud Platform
- Direct API integration
- No additional infrastructure
- Fastest deployment

### Method 2: Self-Hosted qscanner
Best for: Air-gapped or highly regulated environments
- Deploy qscanner on Azure VM or ACI
- Full control over scanning infrastructure
- Network isolation support

### Method 3: Qualys Container Sensor
Best for: Runtime security monitoring
- Deploy sensors alongside containers
- Continuous monitoring
- Advanced threat detection

## Quick Start

### Prerequisites

- Azure subscription with Contributor access
- Azure CLI installed
- Qualys account with API credentials
- Python 3.9+ (for local development)

### 1. Clone and Configure

```bash
git clone <repository-url>
cd qualys-aci

# Copy and configure settings
cp config/config.sample.json config/config.json
# Edit config/config.json with your Qualys credentials and Azure settings
```

### 2. Deploy Infrastructure

```bash
cd infrastructure
chmod +x deploy.sh
./deploy.sh -s <subscription-id> -r <resource-group> -l <location>
```

### 3. Configure Event Grid

The deployment script automatically creates:
- Event Grid subscription for ACI deployments
- Event Grid subscription for ACA deployments
- Function App with managed identity
- Storage account for results

### 4. Verify Deployment

```bash
# Test the function
cd ../function_app
python test_function.py

# Deploy a test container
az container create --resource-group test-rg --name test-container --image nginx:latest
```

## Configuration

### Environment Variables

Configure these in Azure Function App settings or `local.settings.json`:

| Variable | Description | Required |
|----------|-------------|----------|
| `QUALYS_API_URL` | Qualys API endpoint (e.g., https://qualysapi.qualys.com) | Yes |
| `QUALYS_USERNAME` | Qualys API username | Yes |
| `QUALYS_PASSWORD` | Qualys API password | Yes |
| `QUALYS_SCANNER_APPLIANCE_ID` | Scanner appliance ID (if using self-hosted) | No |
| `SCAN_TIMEOUT` | Maximum scan time in seconds (default: 1800) | No |
| `STORAGE_CONNECTION_STRING` | Azure Storage for results | Yes |
| `NOTIFICATION_EMAIL` | Email for scan failure alerts | No |

### Qualys API Configuration

Edit `config/config.json`:

```json
{
  "qualys": {
    "api_url": "https://qualysapi.qualys.com",
    "api_version": "v1",
    "scanner_type": "cloud",
    "scan_options": {
      "include_vulnerabilities": true,
      "include_compliance": true,
      "severity_threshold": "MEDIUM"
    }
  },
  "azure": {
    "subscription_id": "your-subscription-id",
    "resource_groups": ["*"],
    "event_filters": {
      "aci": true,
      "aca": true
    }
  },
  "scanning": {
    "auto_scan": true,
    "scan_private_registries": true,
    "retry_attempts": 3,
    "notify_on_high_severity": true
  }
}
```

## Architecture Details

### Event Flow

1. **Container Deployment**: User deploys container to ACI or ACA
2. **Event Emission**: Azure emits "Microsoft.ContainerInstance/containerGroups/write" or "Microsoft.App/containerApps/write" event
3. **Event Grid Routing**: Event Grid filters and routes to Function App
4. **Event Processing**: Function extracts image name, registry, and tags
5. **Registry Authentication**: Function authenticates to Azure Container Registry (if needed)
6. **Scan Trigger**: Function calls Qualys API to initiate scan
7. **Result Processing**: Function receives and stores scan results
8. **Alerting**: Function sends alerts if vulnerabilities exceed threshold

### Security Considerations

- **Managed Identity**: Function uses Azure Managed Identity to access resources
- **Key Vault Integration**: Qualys credentials stored in Azure Key Vault
- **Private Endpoints**: Support for scanning private registries
- **Network Isolation**: Can be deployed in VNet with private endpoints
- **RBAC**: Minimal permissions following least-privilege principle

## Monitoring

### Application Insights Queries

View recent scans:
```kusto
traces
| where customDimensions.EventType == "ContainerScan"
| project timestamp, severityLevel, message, customDimensions
| order by timestamp desc
```

Failed scans:
```kusto
exceptions
| where customDimensions.Component == "QualysScanner"
| project timestamp, problemId, outerMessage, customDimensions
```

### Alerts

Pre-configured alerts for:
- Scan failures
- High/Critical vulnerabilities detected
- Function execution failures
- API rate limit warnings

## Troubleshooting

### Common Issues

**Event Grid not triggering:**
- Verify Event Grid subscription is active
- Check event filters match your deployment
- Review Event Grid metrics in Azure Portal

**Qualys API errors:**
- Verify API credentials in Key Vault
- Check API endpoint URL
- Ensure scanner appliance is online (self-hosted)

**Private registry access:**
- Verify Managed Identity has AcrPull role
- Check registry allows Azure service access
- Review NSG/firewall rules

### Debug Locally

```bash
cd function_app
pip install -r requirements.txt
func start
```

Test with sample event:
```bash
curl -X POST http://localhost:7071/api/EventProcessor \
  -H "Content-Type: application/json" \
  -d @test_events/aci_deployment.json
```

## Production Considerations

### Scaling
- Function App scales automatically (Consumption or Premium plan)
- For high volume, consider Premium plan with VNet integration
- Event Grid handles up to 10 million events/second

### Cost Optimization
- Use Consumption plan for sporadic deployments
- Implement image caching to avoid duplicate scans
- Set appropriate scan retention policies

### Compliance
- Enable audit logging for all scans
- Store scan results for required retention period
- Implement policy enforcement (block vulnerable containers)

## Advanced Features

### Policy Enforcement
Block deployments with vulnerabilities:
```bash
# Deploy with Azure Policy integration
./infrastructure/deploy.sh -s <sub-id> -r <rg> -l <location> --enable-policy
```

### Custom Scan Profiles
Create custom scan configurations in `config/scan_profiles/`:
```json
{
  "profile_name": "production",
  "scan_options": {
    "severity_threshold": "HIGH",
    "block_deployment": true,
    "max_age_days": 30
  }
}
```

### Multi-Region Deployment
Deploy across regions for high availability:
```bash
./infrastructure/deploy-multi-region.sh
```

## Support and Contributing

- Report issues via GitHub Issues
- Contribute via Pull Requests
- Documentation: [Full documentation](docs/)

## License

MIT License - see LICENSE file for details