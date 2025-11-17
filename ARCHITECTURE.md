# Architecture Deep Dive

This document provides a detailed technical overview of the Qualys Azure Container Scanner architecture.

## System Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     Azure Subscription                           │
│                                                                   │
│  ┌──────────────┐        ┌──────────────┐                       │
│  │     ACI      │        │     ACA      │                       │
│  │  Container   │        │  Container   │                       │
│  │    Groups    │        │     Apps     │                       │
│  └──────┬───────┘        └──────┬───────┘                       │
│         │                       │                                │
│         │ Deployment Events     │                                │
│         └───────────┬───────────┘                                │
│                     ▼                                             │
│         ┌───────────────────────┐                                │
│         │  Azure Event Grid     │                                │
│         │  (System Topic)       │                                │
│         │  - Filter ACI/ACA     │                                │
│         │  - Route to Function  │                                │
│         └───────────┬───────────┘                                │
│                     ▼                                             │
│         ┌───────────────────────┐                                │
│         │  Azure Function App   │                                │
│         │  ┌─────────────────┐  │                                │
│         │  │ EventProcessor  │  │                                │
│         │  │  Function       │  │                                │
│         │  └────────┬────────┘  │                                │
│         │           │            │                                │
│         │  ┌────────▼─────────┐ │                                │
│         │  │  Image Parser    │ │                                │
│         │  └────────┬─────────┘ │                                │
│         │           │            │                                │
│         │  ┌────────▼─────────┐ │                                │
│         │  │ Qualys Scanner   │─┼───────┐                        │
│         │  │   Integration    │ │       │                        │
│         │  └────────┬─────────┘ │       │                        │
│         │           │            │       │                        │
│         │  ┌────────▼─────────┐ │       │                        │
│         │  │Storage Handler   │ │       │                        │
│         │  └──────────────────┘ │       │                        │
│         └───────────┬───────────┘       │                        │
│                     │                    │                        │
│         ┌───────────▼───────────┐       │                        │
│         │  Azure Key Vault      │       │                        │
│         │  - Qualys Credentials │       │                        │
│         │  - API Keys           │       │                        │
│         └───────────────────────┘       │                        │
│                                          │                        │
│         ┌───────────────────────┐       │                        │
│         │  Azure Storage        │       │                        │
│         │  - Blob: Results      │       │                        │
│         │  - Table: Metadata    │       │                        │
│         └───────────────────────┘       │                        │
│                                          │                        │
│         ┌───────────────────────┐       │                        │
│         │ Application Insights  │       │                        │
│         │  - Logs & Metrics     │       │                        │
│         │  - Alerts             │       │                        │
│         └───────────────────────┘       │                        │
└──────────────────────────────────────────┼────────────────────────┘
                                           │
                                           │ HTTPS API
                                           ▼
                              ┌────────────────────────┐
                              │   Qualys Cloud API     │
                              │   - Container Security │
                              │   - Vulnerability DB   │
                              │   - Compliance Engine  │
                              └────────────────────────┘
```

## Component Details

### 1. Event Detection Layer

#### Azure Event Grid
- **Type**: System Topic (Resource Groups)
- **Event Types Monitored**:
  - `Microsoft.Resources.ResourceWriteSuccess`
- **Filters**:
  - ACI: `Microsoft.ContainerInstance/containerGroups/write`
  - ACA: `Microsoft.App/containerApps/write`
- **Delivery**:
  - Target: Azure Function (EventProcessor)
  - Retry: 30 attempts over 24 hours
  - Dead-letter: Optional blob storage

**Event Flow**:
1. User deploys container via Azure Portal, CLI, or ARM template
2. Azure Resource Manager emits event
3. Event Grid receives and filters event
4. Event routed to Function App endpoint
5. Function validates event and extracts data

### 2. Processing Layer

#### Azure Function App

**Runtime**: Python 3.11 on Linux
**Hosting Plan Options**:
- Consumption (Y1): Pay-per-execution, auto-scale
- Elastic Premium (EP1-EP3): Pre-warmed, VNet support

**EventProcessor Function**:
```python
Trigger: Event Grid
Input: EventGridEvent
Processing:
  1. Parse event data
  2. Extract container images
  3. Validate image format
  4. Check scan cache
  5. Trigger Qualys scan
  6. Store results
  7. Send alerts if needed
```

**Key Features**:
- Managed Identity for Azure resource access
- Key Vault integration for secrets
- Automatic retry logic
- Concurrent processing support
- Application Insights telemetry

### 3. Scanning Layer

#### Qualys Scanner Integration

**API Client** (`qualys_scanner.py`):
- RESTful API integration
- HTTP Basic Authentication
- Asynchronous scan submission
- Poll-based result retrieval
- Comprehensive error handling

**Scan Workflow**:
```
1. Submit Scan Request
   POST /csapi/v1.3/images/scan
   Body: {imageId, registry, repository, tag}
   Response: {scanId}

2. Monitor Scan Status (polling)
   GET /csapi/v1.3/images/scan/{scanId}/status
   Response: {status: PENDING|RUNNING|COMPLETED|FAILED}
   Poll interval: 10 seconds
   Max duration: configurable (default 30 min)

3. Retrieve Results
   GET /csapi/v1.3/images/scan/{scanId}/results
   Response: {vulnerabilities[], compliance[], metadata}

4. Parse and Store
   Extract vulnerability counts by severity
   Extract compliance check results
   Store in Azure Storage
```

**Image Parser** (`image_parser.py`):
Handles various image name formats:
- `nginx` → `docker.io/library/nginx:latest`
- `myacr.azurecr.io/app:v1` → parsed registry/repo/tag
- `mcr.microsoft.com/dotnet:6.0` → Microsoft registry
- Image digests: `image@sha256:abc123...`

### 4. Storage Layer

#### Azure Blob Storage
**Container**: `scan-results`
**Structure**:
```
scan-results/
├── docker.io_library_nginx_latest/
│   ├── scan-20240115-123456.json
│   └── scan-20240116-234567.json
├── myacr.azurecr.io_myapp_v1.2.3/
│   └── scan-20240115-145623.json
└── errors/
    └── failed-image-20240115-120000.json
```

**Blob Metadata**:
- Image name
- Scan ID
- Timestamp
- Container type (ACI/ACA)

#### Azure Table Storage
**Table**: `ScanMetadata`
**Schema**:
| Column | Type | Description |
|--------|------|-------------|
| PartitionKey | String | Sanitized image name |
| RowKey | String | Scan ID |
| Image | String | Full image identifier |
| Timestamp | DateTime | Scan completion time |
| Status | String | COMPLETED/FAILED |
| ContainerType | String | ACI/ACA |
| VulnCritical | Int32 | Critical vulnerability count |
| VulnHigh | Int32 | High vulnerability count |
| VulnMedium | Int32 | Medium vulnerability count |
| VulnLow | Int32 | Low vulnerability count |
| VulnTotal | Int32 | Total vulnerability count |
| CompliancePassed | Int32 | Passed compliance checks |
| ComplianceFailed | Int32 | Failed compliance checks |
| BlobPath | String | Path to detailed results |

**Query Patterns**:
- Get all scans for an image: `PartitionKey eq '<image>'`
- Recent scans: `Timestamp ge datetime'2024-01-15T00:00:00Z'`
- High-severity findings: `VulnCritical gt 0 or VulnHigh gt 0`

### 5. Security Layer

#### Azure Key Vault
**Secrets Stored**:
- `QualysApiUrl`: Qualys API endpoint
- `QualysUsername`: API username
- `QualysPassword`: API password
- (Optional) `QualysScannerApplianceId`: Self-hosted scanner ID

**Access Control**:
- RBAC enabled (not access policies)
- Function App Managed Identity granted "Key Vault Secrets User" role
- Key Vault references in App Settings: `@Microsoft.KeyVault(SecretUri=...)`
- Soft delete enabled (90-day retention)

#### Managed Identity
Function App system-assigned managed identity used for:
1. Key Vault secret access
2. Storage account access (alternative to connection strings)
3. Azure Container Registry access (AcrPull role)
4. Event Grid authentication

### 6. Monitoring Layer

#### Application Insights

**Telemetry Collected**:
- Request traces (function invocations)
- Custom events (scan initiations, completions)
- Exceptions (scan failures, API errors)
- Dependencies (HTTP calls to Qualys API)
- Metrics (scan duration, vulnerability counts)

**Custom Dimensions**:
```json
{
  "EventType": "ContainerScan",
  "Image": "nginx:latest",
  "ContainerType": "ACI",
  "ScanId": "scan-123456",
  "VulnCritical": 2,
  "VulnHigh": 5,
  "Duration": 45.3
}
```

**Pre-built Queries**:
```kusto
// Recent scans
traces
| where customDimensions.EventType == "ContainerScan"
| project timestamp, severityLevel, message, customDimensions
| order by timestamp desc

// Failed scans
exceptions
| where customDimensions.Component == "QualysScanner"
| summarize count() by problemId, outerMessage

// Scan performance
dependencies
| where name contains "qualysapi"
| summarize avg(duration), max(duration) by bin(timestamp, 1h)

// High-severity findings
traces
| where customDimensions.VulnCritical > 0 or customDimensions.VulnHigh > 0
| project timestamp, Image=customDimensions.Image,
          Critical=customDimensions.VulnCritical,
          High=customDimensions.VulnHigh
```

## Data Flow Diagrams

### Successful Scan Flow
```
User → Deploy ACI/ACA
  ↓
Azure RM → Emit Event
  ↓
Event Grid → Filter & Route
  ↓
Function → Receive Event
  ↓
Function → Parse Image Names
  ↓
Function → Check Cache (Table Storage)
  ↓ (if not cached)
Function → Submit Scan (Qualys API)
  ↓
Qualys → Process Image
  ↓
Function → Poll Status (every 10s)
  ↓ (when complete)
Function → Fetch Results (Qualys API)
  ↓
Function → Parse Vulnerabilities
  ↓
Function → Store Blob (detailed JSON)
  ↓
Function → Store Table Entry (metadata)
  ↓
Function → Check Severity Threshold
  ↓ (if exceeded)
Function → Send Alert
  ↓
Complete
```

### Error Handling Flow
```
Event → Function
  ↓
Try: Parse Event
  ↓ (exception)
  Catch: Log Error → App Insights
         Store Error → Blob Storage
         Return 500
  ↓
Event Grid → Retry (exponential backoff)
  ↓ (after max retries)
Event Grid → Dead Letter Queue (optional)
```

## Scalability Considerations

### Horizontal Scaling
- **Function App**: Auto-scales based on Event Grid queue depth
- **Consumption Plan**: Up to 200 instances
- **Premium Plan**: Up to 100 instances (configurable)
- **Event Grid**: Handles 10M events/second

### Parallel Processing
```python
# Function processes events in parallel automatically
# Each event = separate function invocation
# Concurrency controlled by:
- FUNCTIONS_WORKER_PROCESS_COUNT (default: 1)
- maxConcurrentRequests in host.json
```

### Scan Deduplication
```python
# Check if image scanned recently (default 24h)
if storage.is_recently_scanned(image, hours=24):
    skip_scan()
else:
    perform_scan()
```

### Rate Limiting
Qualys API rate limits (varies by subscription):
- Typical: 300 requests/hour per user
- Burst: 30 requests/minute

**Mitigation**:
- Cache scan results (24h default)
- Retry with exponential backoff
- Queue scans during high volume

## Network Architecture

### Standard Deployment
```
Function App (Public)
  ↓ HTTPS
Qualys Cloud API (Public)
  ↓ HTTPS
Azure Storage (Public with firewall)
  ↓ HTTPS
Key Vault (Public)
```

### Secure Deployment (Premium Plan)
```
Function App (VNet Integrated)
  ↓ Private Endpoint
Azure Storage (Private)
  ↓ Private Endpoint
Key Vault (Private)
  ↓ Service Endpoint
Qualys Cloud API (Public via NAT Gateway)
```

## Performance Metrics

**Typical Scan Duration**:
- Small image (<100MB): 30-60 seconds
- Medium image (100-500MB): 1-3 minutes
- Large image (>500MB): 3-10 minutes

**Function Execution**:
- Cold start: 5-15 seconds (Consumption)
- Warm start: <1 second
- Total execution: Scan duration + 5-10 seconds overhead

**Cost Estimates** (per 1000 scans/month):
- Function App (Consumption): $1-5
- Storage: $1-3
- Event Grid: $0.60
- Application Insights: $2-10
- Total: ~$5-20/month (excluding Qualys subscription)

## High Availability

### Multi-Region Deployment
For critical workloads, deploy across regions:
```
Primary Region (East US)
├── Function App
├── Storage Account
└── Event Grid

Secondary Region (West US)
├── Function App (standby)
├── Storage Account (geo-replicated)
└── Event Grid

Traffic Manager or Front Door
└── Health probes
└── Automatic failover
```

### Disaster Recovery
- Storage: GRS (Geo-Redundant Storage) for automatic replication
- Function App: ARM template for quick re-deployment
- Key Vault: Soft delete + backup secrets
- RPO (Recovery Point Objective): <1 hour
- RTO (Recovery Time Objective): <30 minutes

## Security Architecture

### Defense in Depth
1. **Network**: VNet integration, private endpoints, NSGs
2. **Identity**: Managed identities, RBAC, least privilege
3. **Data**: Encryption at rest, TLS in transit, Key Vault
4. **Application**: Input validation, secure coding practices
5. **Monitoring**: Audit logs, alerts, SIEM integration

### Compliance
- **Data Residency**: Deploy in required region
- **Encryption**: AES-256 at rest, TLS 1.2+ in transit
- **Audit**: All operations logged to Azure Monitor
- **Retention**: Configurable (90 days default)

## Extension Points

### Custom Scan Profiles
Implement in `qualys_scanner.py`:
```python
def scan_image(self, ..., profile='default'):
    scan_config = load_profile(profile)
    # Apply custom scan settings
```

### Notification Integrations
Extend `send_alert()` in `__init__.py`:
- SendGrid for email
- Microsoft Teams via webhook
- Slack via webhook
- PagerDuty API
- ServiceNow incidents

### Policy Enforcement
Add post-scan action:
```python
if vulnerabilities['CRITICAL'] > 0:
    # Tag container group for deletion
    # Send to approval workflow
    # Block deployment via Azure Policy
```

### Multi-Scanner Support
Abstract scanner interface:
```python
class ScannerInterface(ABC):
    @abstractmethod
    def scan_image(self, image): pass

class QualysScanner(ScannerInterface): ...
class TrivyScanner(ScannerInterface): ...
class SnykScanner(ScannerInterface): ...
```
