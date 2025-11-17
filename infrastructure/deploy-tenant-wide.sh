#!/bin/bash

# Deploy tenant-wide Qualys container scanning
# Monitors ALL subscriptions in the tenant for ACI/ACA deployments

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_success() {
    echo -e "${GREEN}$1${NC}"
}

print_error() {
    echo -e "${RED}$1${NC}"
}

print_info() {
    echo -e "${YELLOW}$1${NC}"
}

usage() {
    cat << EOF
Usage: $0 -m <management-group-id> -s <function-subscription-id> -r <function-resource-group> -f <function-app-name>

Deploy tenant-wide Event Grid subscriptions to monitor ALL subscriptions for container deployments.

Required:
    -m, --management-group    Management Group ID (use tenant root for entire tenant)
    -s, --subscription        Subscription ID where Function App is deployed
    -r, --resource-group      Resource group where Function App is deployed
    -f, --function-app        Function App name

Optional:
    -p, --prefix              Name prefix for event subscriptions (default: qualys-scanner)
    -h, --help                Display this help message

Example - Monitor entire tenant:
    # First get tenant root management group ID
    TENANT_ROOT=\$(az account management-group list --query "[?displayName=='Tenant Root Group'].name" -o tsv)

    # Deploy tenant-wide monitoring
    $0 \\
      -m "\$TENANT_ROOT" \\
      -s "12345678-1234-1234-1234-123456789012" \\
      -r "qualys-scanner-rg" \\
      -f "qualys-scanner-func-abc123"

Example - Monitor specific management group:
    $0 \\
      -m "production-mg" \\
      -s "12345678-1234-1234-1234-123456789012" \\
      -r "qualys-scanner-rg" \\
      -f "qualys-scanner-func-abc123"
EOF
    exit 1
}

MANAGEMENT_GROUP=""
FUNCTION_SUBSCRIPTION=""
FUNCTION_RESOURCE_GROUP=""
FUNCTION_APP_NAME=""
NAME_PREFIX="qualys-scanner"

while [[ $# -gt 0 ]]; do
    case $1 in
        -m|--management-group)
            MANAGEMENT_GROUP="$2"
            shift 2
            ;;
        -s|--subscription)
            FUNCTION_SUBSCRIPTION="$2"
            shift 2
            ;;
        -r|--resource-group)
            FUNCTION_RESOURCE_GROUP="$2"
            shift 2
            ;;
        -f|--function-app)
            FUNCTION_APP_NAME="$2"
            shift 2
            ;;
        -p|--prefix)
            NAME_PREFIX="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            print_error "Unknown option: $1"
            usage
            ;;
    esac
done

if [ -z "$MANAGEMENT_GROUP" ] || [ -z "$FUNCTION_SUBSCRIPTION" ] || [ -z "$FUNCTION_RESOURCE_GROUP" ] || [ -z "$FUNCTION_APP_NAME" ]; then
    print_error "Missing required arguments"
    usage
fi

print_info "Deploying tenant-wide Qualys container scanning"
echo "Management Group: $MANAGEMENT_GROUP"
echo "Function Subscription: $FUNCTION_SUBSCRIPTION"
echo "Function Resource Group: $FUNCTION_RESOURCE_GROUP"
echo "Function App: $FUNCTION_APP_NAME"
echo ""

# Verify management group exists
print_info "Verifying management group access..."
if ! az account management-group show --name "$MANAGEMENT_GROUP" &> /dev/null; then
    print_error "Cannot access management group '$MANAGEMENT_GROUP'"
    print_error "Ensure you have read permissions on the management group"
    exit 1
fi
print_success "Management group verified"

# Verify function app exists
print_info "Verifying Function App..."
if ! az functionapp show --name "$FUNCTION_APP_NAME" --resource-group "$FUNCTION_RESOURCE_GROUP" --subscription "$FUNCTION_SUBSCRIPTION" &> /dev/null; then
    print_error "Function App '$FUNCTION_APP_NAME' not found"
    print_error "Deploy the Function App first using infrastructure/deploy.sh"
    exit 1
fi
print_success "Function App verified"

# Deploy Event Grid subscriptions at management group scope
print_info "Deploying Event Grid subscriptions at management group scope..."

DEPLOYMENT_NAME="qualys-scanner-tenant-wide-$(date +%Y%m%d-%H%M%S)"

az deployment mg create \
    --name "$DEPLOYMENT_NAME" \
    --management-group-id "$MANAGEMENT_GROUP" \
    --location "eastus" \
    --template-file "$(dirname "$0")/tenant-wide.bicep" \
    --parameters \
        managementGroupId="$MANAGEMENT_GROUP" \
        functionSubscriptionId="$FUNCTION_SUBSCRIPTION" \
        functionResourceGroup="$FUNCTION_RESOURCE_GROUP" \
        functionAppName="$FUNCTION_APP_NAME" \
        namePrefix="$NAME_PREFIX"

if [ $? -eq 0 ]; then
    print_success "Tenant-wide monitoring deployed successfully"
else
    print_error "Deployment failed"
    exit 1
fi

# Get list of subscriptions that will be monitored
print_info "Checking subscriptions that will be monitored..."
SUBSCRIPTION_COUNT=$(az account management-group show \
    --name "$MANAGEMENT_GROUP" \
    --expand \
    --recurse \
    --query "children[?type=='Microsoft.Management/managementGroups/subscriptions'] | length(@)" \
    -o tsv)

echo ""
print_success "Deployment complete!"
echo ""
echo "Monitoring Configuration:"
echo "  Management Group: $MANAGEMENT_GROUP"
echo "  Subscriptions monitored: $SUBSCRIPTION_COUNT (including all child management groups)"
echo "  Event types: ACI and ACA container deployments"
echo "  Function App: $FUNCTION_APP_NAME"
echo ""
echo "Event Grid Subscriptions:"
echo "  ACI: ${NAME_PREFIX}-aci-tenant-wide"
echo "  ACA: ${NAME_PREFIX}-aca-tenant-wide"
echo ""
print_info "Any ACI or ACA deployment in ANY subscription under this management group will now trigger scans"
echo ""
echo "To view monitored subscriptions:"
echo "  az account management-group show --name $MANAGEMENT_GROUP --expand --recurse"
echo ""
echo "To verify Event Grid subscriptions:"
echo "  az eventgrid event-subscription list --source-resource-id /providers/Microsoft.Management/managementGroups/$MANAGEMENT_GROUP"
