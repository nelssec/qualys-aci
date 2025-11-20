#!/bin/bash
# Add spoke subscription to multi-subscription scanner
# Reads configuration from .deployment-outputs.json created by deploy-multi.sh

set -e

OUTPUTS_FILE=".deployment-outputs.json"
SPOKE_SUB="${SPOKE_SUBSCRIPTION_ID:-}"
LOCATION="${LOCATION:-eastus}"

if [ ! -f "$OUTPUTS_FILE" ]; then
  echo "ERROR: Deployment outputs file not found: $OUTPUTS_FILE"
  echo "You must run ./deploy-multi.sh first to deploy the central hub"
  exit 1
fi

if [ -z "$SPOKE_SUB" ]; then
  echo "ERROR: SPOKE_SUBSCRIPTION_ID environment variable not set"
  echo "Usage: export SPOKE_SUBSCRIPTION_ID='<subscription-id>' && ./add-spoke.sh"
  exit 1
fi

# Extract values from central deployment
CENTRAL_SUB=$(jq -r '.centralSubscriptionId.value' "$OUTPUTS_FILE")
CENTRAL_RG=$(jq -r '.resourceGroupName.value' "$OUTPUTS_FILE")
EVENT_HUB_NAMESPACE=$(jq -r '.eventHubNamespace.value' "$OUTPUTS_FILE")
EVENT_HUB_CONN_STRING=$(jq -r '.diagnosticsSendConnectionString.value' "$OUTPUTS_FILE")
FUNCTION_PRINCIPAL_ID=$(jq -r '.functionAppPrincipalId.value' "$OUTPUTS_FILE")

echo "============================================"
echo "Adding Spoke Subscription"
echo "============================================"
echo ""
echo "Central Subscription: $CENTRAL_SUB"
echo "Spoke Subscription: $SPOKE_SUB"
echo "Event Hub Namespace: $EVENT_HUB_NAMESPACE"
echo ""

# Switch to spoke subscription
echo "Switching to spoke subscription: $SPOKE_SUB"
az account set --subscription "$SPOKE_SUB"

# Deploy spoke configuration
echo "Deploying spoke configuration..."
az deployment sub create \
  --location "$LOCATION" \
  --template-file infrastructure/spoke.bicep \
  --parameters centralSubscriptionId="$CENTRAL_SUB" \
  --parameters centralResourceGroupName="$CENTRAL_RG" \
  --parameters eventHubNamespace="$EVENT_HUB_NAMESPACE" \
  --parameters eventHubSendConnectionString="$EVENT_HUB_CONN_STRING" \
  --parameters functionAppPrincipalId="$FUNCTION_PRINCIPAL_ID" \
  --output none

if [ $? -ne 0 ]; then
  echo "ERROR: Spoke deployment failed"
  exit 1
fi

echo ""
echo "============================================"
echo "Spoke Subscription Added Successfully"
echo "============================================"
echo ""
echo "Spoke subscription $SPOKE_SUB is now configured."
echo "Container deployments in this subscription will be scanned by the central scanner."
echo ""
echo "Configured:"
echo "  - Activity Log → Central Event Hub"
echo "  - Reader role for function app"
echo "  - AcrPull role for function app"
echo ""
echo "Test by deploying a container in this subscription:"
echo "  az container create --resource-group test-rg --name test-scan \\"
echo "    --image mcr.microsoft.com/dotnet/runtime:8.0 \\"
echo "    --os-type Linux --cpu 1 --memory 1 --restart-policy Never"
echo ""
