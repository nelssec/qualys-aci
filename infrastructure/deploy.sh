#!/bin/bash

set -e

usage() {
    echo "Usage: $0 --resource-group <rg-name> --location <location> --qualys-token <token> [options]"
    echo ""
    echo "Required:"
    echo "  --resource-group <name>    Resource group name"
    echo "  --location <location>      Azure region (e.g., eastus)"
    echo "  --qualys-token <token>     Qualys access token"
    echo ""
    echo "Optional:"
    echo "  --subscription <id>        Azure subscription ID (uses current if not specified)"
    echo "  --skip-validation          Skip pre-deployment validation"
    echo "  --param-file <file>        Bicep parameter file (default: main.bicepparam)"
    echo "  --help                     Show this help message"
    echo ""
    exit 1
}

RESOURCE_GROUP=""
LOCATION=""
QUALYS_TOKEN=""
SUBSCRIPTION=""
SKIP_VALIDATION=false
PARAM_FILE="main.bicepparam"

while [[ $# -gt 0 ]]; do
    case $1 in
        --resource-group)
            RESOURCE_GROUP="$2"
            shift 2
            ;;
        --location)
            LOCATION="$2"
            shift 2
            ;;
        --qualys-token)
            QUALYS_TOKEN="$2"
            shift 2
            ;;
        --subscription)
            SUBSCRIPTION="$2"
            shift 2
            ;;
        --skip-validation)
            SKIP_VALIDATION=true
            shift
            ;;
        --param-file)
            PARAM_FILE="$2"
            shift 2
            ;;
        --help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

if [ -z "$RESOURCE_GROUP" ] || [ -z "$LOCATION" ] || [ -z "$QUALYS_TOKEN" ]; then
    echo "ERROR: Missing required arguments"
    usage
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [ -n "$SUBSCRIPTION" ]; then
    echo "Setting subscription to $SUBSCRIPTION..."
    az account set --subscription "$SUBSCRIPTION"
fi

SUBSCRIPTION_ID=$(az account show --query id -o tsv)
SUBSCRIPTION_NAME=$(az account show --query name -o tsv)

echo "=== Deployment Configuration ==="
echo "Subscription: $SUBSCRIPTION_NAME ($SUBSCRIPTION_ID)"
echo "Resource Group: $RESOURCE_GROUP"
echo "Location: $LOCATION"
echo "Parameter File: $PARAM_FILE"
echo ""

if [ "$SKIP_VALIDATION" = false ]; then
    echo "=== Running Pre-Deployment Validation ==="
    bash ./pre-deploy-check.sh "$LOCATION" || {
        echo ""
        echo "Pre-deployment validation failed. Fix errors and try again."
        echo "Use --skip-validation to bypass (not recommended)"
        exit 1
    }
    echo ""
fi

echo "=== Step 1: Creating Resource Group ==="
az group create \
    --name "$RESOURCE_GROUP" \
    --location "$LOCATION"
echo ""

echo "=== Step 2: Initial Infrastructure Deployment ==="
echo "This deploys all resources except Event Grid subscriptions may not validate yet"
az deployment group create \
    --resource-group "$RESOURCE_GROUP" \
    --template-file main.bicep \
    --parameters "$PARAM_FILE" \
    --parameters qualysAccessToken="$QUALYS_TOKEN"

echo ""
echo "=== Step 3: Retrieving Function App Name ==="
FUNCTION_APP=$(az deployment group show \
    --resource-group "$RESOURCE_GROUP" \
    --name main \
    --query properties.outputs.functionAppName.value -o tsv)

if [ -z "$FUNCTION_APP" ]; then
    echo "ERROR: Failed to retrieve function app name from deployment outputs"
    exit 1
fi

echo "Function App: $FUNCTION_APP"
echo ""

echo "=== Step 4: Deploying Function Code ==="
cd ../function_app

if ! command -v func &> /dev/null; then
    echo "ERROR: Azure Functions Core Tools not found"
    echo "Install from https://docs.microsoft.com/en-us/azure/azure-functions/functions-run-local"
    exit 1
fi

echo "Building and publishing function app (this may take a few minutes)..."
func azure functionapp publish "$FUNCTION_APP" --build remote

cd "$SCRIPT_DIR"
echo ""

echo "=== Step 5: Redeploying Infrastructure for Event Grid ==="
echo "This ensures Event Grid subscriptions can validate the function endpoint"
az deployment group create \
    --resource-group "$RESOURCE_GROUP" \
    --template-file main.bicep \
    --parameters "$PARAM_FILE" \
    --parameters qualysAccessToken="$QUALYS_TOKEN" \
    --mode Incremental

echo ""
echo "=== Deployment Complete ==="
echo ""

STORAGE_ACCOUNT=$(az deployment group show \
    --resource-group "$RESOURCE_GROUP" \
    --name main \
    --query properties.outputs.storageAccountName.value -o tsv)

KEY_VAULT=$(az deployment group show \
    --resource-group "$RESOURCE_GROUP" \
    --name main \
    --query properties.outputs.keyVaultName.value -o tsv)

APP_INSIGHTS=$(az deployment group show \
    --resource-group "$RESOURCE_GROUP" \
    --name main \
    --query properties.outputs.appInsightsName.value -o tsv)

FUNCTION_URL=$(az deployment group show \
    --resource-group "$RESOURCE_GROUP" \
    --name main \
    --query properties.outputs.functionAppUrl.value -o tsv)

echo "Deployed Resources:"
echo "  Function App: $FUNCTION_APP"
echo "  Function URL: $FUNCTION_URL"
echo "  Storage Account: $STORAGE_ACCOUNT"
echo "  Key Vault: $KEY_VAULT"
echo "  App Insights: $APP_INSIGHTS"
echo ""

echo "=== Verification Steps ==="
echo ""
echo "1. Check Event Grid subscriptions:"
echo "   az eventgrid system-topic event-subscription list \\"
echo "     --resource-group $RESOURCE_GROUP \\"
echo "     --system-topic-name qualys-scanner-aci-topic"
echo ""
echo "2. Test with a container deployment:"
echo "   az container create \\"
echo "     --resource-group test-rg \\"
echo "     --name test-nginx \\"
echo "     --image nginx:latest \\"
echo "     --cpu 1 --memory 1"
echo ""
echo "3. Monitor scans in Application Insights:"
echo "   az monitor app-insights query \\"
echo "     --app $APP_INSIGHTS \\"
echo "     --analytics-query \"traces | where timestamp > ago(30m) | where message contains 'Scan' | order by timestamp desc\""
echo ""
