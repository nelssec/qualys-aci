#!/bin/bash

# Deployment script for Qualys ACI/ACA Scanner
# This script deploys the Azure infrastructure and function app

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${YELLOW}ℹ $1${NC}"
}

# Function to display usage
usage() {
    cat << EOF
Usage: $0 -s <subscription-id> -r <resource-group> -l <location> [OPTIONS]

Required arguments:
    -s, --subscription      Azure subscription ID
    -r, --resource-group    Resource group name
    -l, --location          Azure region (e.g., eastus, westus2)

Optional arguments:
    -p, --prefix            Name prefix for resources (default: qualys-scanner)
    -u, --qualys-url        Qualys API URL (default: https://qualysapi.qualys.com)
    -n, --qualys-user       Qualys username (required if not in env)
    -w, --qualys-pass       Qualys password (required if not in env)
    -e, --email             Notification email address
    -k, --sku               Function App SKU (Y1, EP1, EP2, EP3) (default: Y1)
    --deploy-function       Deploy function app code after infrastructure
    --enable-policy         Enable Azure Policy enforcement (experimental)
    -h, --help              Display this help message

Environment variables:
    QUALYS_USERNAME         Qualys API username (alternative to -n)
    QUALYS_PASSWORD         Qualys API password (alternative to -w)

Example:
    $0 -s "12345678-1234-1234-1234-123456789012" \\
       -r "qualys-scanner-rg" \\
       -l "eastus" \\
       -n "qualys_user" \\
       -w "qualys_pass" \\
       -e "security@example.com" \\
       --deploy-function
EOF
    exit 1
}

# Parse command line arguments
SUBSCRIPTION=""
RESOURCE_GROUP=""
LOCATION=""
NAME_PREFIX="qualys-scanner"
QUALYS_URL="https://qualysapi.qualys.com"
QUALYS_USER="${QUALYS_USERNAME:-}"
QUALYS_PASS="${QUALYS_PASSWORD:-}"
NOTIFICATION_EMAIL=""
FUNCTION_SKU="Y1"
DEPLOY_FUNCTION=false
ENABLE_POLICY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--subscription)
            SUBSCRIPTION="$2"
            shift 2
            ;;
        -r|--resource-group)
            RESOURCE_GROUP="$2"
            shift 2
            ;;
        -l|--location)
            LOCATION="$2"
            shift 2
            ;;
        -p|--prefix)
            NAME_PREFIX="$2"
            shift 2
            ;;
        -u|--qualys-url)
            QUALYS_URL="$2"
            shift 2
            ;;
        -n|--qualys-user)
            QUALYS_USER="$2"
            shift 2
            ;;
        -w|--qualys-pass)
            QUALYS_PASS="$2"
            shift 2
            ;;
        -e|--email)
            NOTIFICATION_EMAIL="$2"
            shift 2
            ;;
        -k|--sku)
            FUNCTION_SKU="$2"
            shift 2
            ;;
        --deploy-function)
            DEPLOY_FUNCTION=true
            shift
            ;;
        --enable-policy)
            ENABLE_POLICY=true
            shift
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

# Validate required arguments
if [ -z "$SUBSCRIPTION" ] || [ -z "$RESOURCE_GROUP" ] || [ -z "$LOCATION" ]; then
    print_error "Missing required arguments"
    usage
fi

if [ -z "$QUALYS_USER" ] || [ -z "$QUALYS_PASS" ]; then
    print_error "Qualys credentials not provided. Use -n/-w flags or set QUALYS_USERNAME/QUALYS_PASSWORD environment variables"
    exit 1
fi

# Check if Azure CLI is installed
if ! command -v az &> /dev/null; then
    print_error "Azure CLI is not installed. Please install it from https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
    exit 1
fi

print_info "Starting deployment of Qualys ACI/ACA Scanner"
echo "Subscription: $SUBSCRIPTION"
echo "Resource Group: $RESOURCE_GROUP"
echo "Location: $LOCATION"
echo "Name Prefix: $NAME_PREFIX"
echo ""

# Set Azure subscription
print_info "Setting Azure subscription..."
az account set --subscription "$SUBSCRIPTION"
print_success "Subscription set"

# Create resource group if it doesn't exist
print_info "Checking resource group..."
if ! az group show --name "$RESOURCE_GROUP" &> /dev/null; then
    print_info "Creating resource group $RESOURCE_GROUP..."
    az group create --name "$RESOURCE_GROUP" --location "$LOCATION"
    print_success "Resource group created"
else
    print_success "Resource group exists"
fi

# Deploy infrastructure using Bicep
print_info "Deploying Azure infrastructure..."
DEPLOYMENT_NAME="qualys-scanner-$(date +%Y%m%d-%H%M%S)"

DEPLOYMENT_OUTPUT=$(az deployment group create \
    --name "$DEPLOYMENT_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --template-file "$(dirname "$0")/main.bicep" \
    --parameters \
        location="$LOCATION" \
        namePrefix="$NAME_PREFIX" \
        qualysApiUrl="$QUALYS_URL" \
        qualysUsername="$QUALYS_USER" \
        qualysPassword="$QUALYS_PASS" \
        notificationEmail="$NOTIFICATION_EMAIL" \
        functionAppSku="$FUNCTION_SKU" \
    --output json)

if [ $? -eq 0 ]; then
    print_success "Infrastructure deployed successfully"
else
    print_error "Infrastructure deployment failed"
    exit 1
fi

# Extract outputs
FUNCTION_APP_NAME=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.properties.outputs.functionAppName.value')
STORAGE_ACCOUNT_NAME=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.properties.outputs.storageAccountName.value')
KEY_VAULT_NAME=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.properties.outputs.keyVaultName.value')

print_success "Function App: $FUNCTION_APP_NAME"
print_success "Storage Account: $STORAGE_ACCOUNT_NAME"
print_success "Key Vault: $KEY_VAULT_NAME"

# Deploy function app code if requested
if [ "$DEPLOY_FUNCTION" = true ]; then
    print_info "Deploying function app code..."

    FUNCTION_DIR="$(dirname "$0")/../function_app"

    if [ ! -d "$FUNCTION_DIR" ]; then
        print_error "Function app directory not found: $FUNCTION_DIR"
        exit 1
    fi

    # Create deployment package
    print_info "Creating deployment package..."
    cd "$FUNCTION_DIR"

    # Install dependencies
    pip install --target ".python_packages/lib/site-packages" -r requirements.txt

    # Create zip package
    zip -r "../function_app.zip" . -x "*.pyc" -x "__pycache__/*" -x "local.settings.json" -x "test_*"

    cd ..

    # Deploy to Azure
    print_info "Uploading to Azure Function App..."
    az functionapp deployment source config-zip \
        --resource-group "$RESOURCE_GROUP" \
        --name "$FUNCTION_APP_NAME" \
        --src "function_app.zip"

    if [ $? -eq 0 ]; then
        print_success "Function app code deployed successfully"
        rm function_app.zip
    else
        print_error "Function app deployment failed"
        exit 1
    fi
fi

# Summary
echo ""
print_success "Deployment completed successfully!"
echo ""
echo "Resource Summary:"
echo "  Resource Group: $RESOURCE_GROUP"
echo "  Function App: $FUNCTION_APP_NAME"
echo "  Storage Account: $STORAGE_ACCOUNT_NAME"
echo "  Key Vault: $KEY_VAULT_NAME"
echo ""
echo "Next Steps:"
echo "  1. Deploy function code: cd function_app && func azure functionapp publish $FUNCTION_APP_NAME"
echo "  2. Monitor logs: az monitor app-insights query --app $FUNCTION_APP_NAME --analytics-query 'traces | order by timestamp desc'"
echo "  3. Test deployment: Deploy a test container to ACI or ACA"
echo ""
print_info "For more information, see the README.md file"
