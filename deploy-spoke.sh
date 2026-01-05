#!/bin/bash
set -e

OUTPUTS_FILE=".deployment-outputs.json"
SPOKE_SUB="${SPOKE_SUBSCRIPTION_ID:-}"
LOCATION="${LOCATION:-eastus}"

if [ ! -f "$OUTPUTS_FILE" ]; then
  echo "ERROR: Deployment outputs file not found: $OUTPUTS_FILE"
  echo "Run ./deploy-hub.sh first to deploy the hub"
  exit 1
fi

if [ -z "$SPOKE_SUB" ]; then
  echo "ERROR: SPOKE_SUBSCRIPTION_ID environment variable not set"
  echo "Usage: export SPOKE_SUBSCRIPTION_ID='<subscription-id>' && ./deploy-spoke.sh"
  exit 1
fi

HUB_SUB=$(jq -r '.centralSubscriptionId.value' "$OUTPUTS_FILE")
HUB_RG=$(jq -r '.resourceGroupName.value' "$OUTPUTS_FILE")
EVENT_HUB_NAMESPACE=$(jq -r '.eventHubNamespace.value' "$OUTPUTS_FILE")
EVENT_HUB_CONN_STRING=$(jq -r '.diagnosticsSendConnectionString.value' "$OUTPUTS_FILE")
FUNCTION_PRINCIPAL_ID=$(jq -r '.functionAppPrincipalId.value' "$OUTPUTS_FILE")

echo "Spoke Deployment"
echo "================"
echo "Hub: $HUB_SUB"
echo "Spoke: $SPOKE_SUB"
echo ""

az account set --subscription "$SPOKE_SUB"

az deployment sub create \
  --location "$LOCATION" \
  --template-file infrastructure/spoke.bicep \
  --parameters centralSubscriptionId="$HUB_SUB" \
  --parameters centralResourceGroupName="$HUB_RG" \
  --parameters eventHubNamespace="$EVENT_HUB_NAMESPACE" \
  --parameters eventHubSendConnectionString="$EVENT_HUB_CONN_STRING" \
  --parameters functionAppPrincipalId="$FUNCTION_PRINCIPAL_ID" \
  --output none

if [ $? -ne 0 ]; then
  echo "ERROR: Spoke deployment failed"
  exit 1
fi

echo ""
echo "Spoke Deployment Complete"
echo "========================="
echo "Container deployments in $SPOKE_SUB will be scanned by the hub"
echo ""
