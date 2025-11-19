#!/bin/bash
# Diagnose Event Grid deployment issues
set -e

RG="${RESOURCE_GROUP:-qualys-scanner-rg}"
LOCATION="${LOCATION:-eastus}"

echo "========================================="
echo "Event Grid Deployment Diagnostics"
echo "========================================="
echo ""

echo "[1/4] Checking existing system topics..."
az eventgrid system-topic list --resource-group "$RG" --query "[].{Name:name,Type:topicType,State:provisioningState}" -o table

echo ""
echo "[2/4] Checking last deployment status..."
DEPLOYMENT=$(az deployment sub list --query "sort_by([?location=='$LOCATION'], &properties.timestamp) | [-1].{Name:name,State:properties.provisioningState,Timestamp:properties.timestamp}" -o table)
echo "$DEPLOYMENT"

echo ""
echo "[3/4] Checking deployment outputs..."
DEPLOYMENT_NAME=$(az deployment sub list --query "sort_by([?location=='$LOCATION'], &properties.timestamp) | [-1].name" -o tsv)
if [ -n "$DEPLOYMENT_NAME" ]; then
  echo "Latest deployment: $DEPLOYMENT_NAME"
  az deployment sub show --name "$DEPLOYMENT_NAME" --query "properties.outputs" -o json
else
  echo "No deployment found"
fi

echo ""
echo "[4/4] Checking for deployment errors..."
if [ -n "$DEPLOYMENT_NAME" ]; then
  ERRORS=$(az deployment sub show --name "$DEPLOYMENT_NAME" --query "properties.error" -o json 2>/dev/null || echo "null")
  if [ "$ERRORS" != "null" ]; then
    echo "[ERROR] Deployment had errors:"
    echo "$ERRORS"
  else
    echo "[OK] No deployment errors found"
  fi
fi

echo ""
echo "========================================="
echo "Checking Event Grid Topic Name Mismatch"
echo "========================================="
echo ""
echo "Expected topic name from Bicep: qscan-aci-topic"
echo ""
ACTUAL_TOPIC=$(az eventgrid system-topic list --resource-group "$RG" --query "[0].name" -o tsv 2>/dev/null || echo "")
echo "Actual topic name in resource group: $ACTUAL_TOPIC"
echo ""

if [ "$ACTUAL_TOPIC" != "qscan-aci-topic" ]; then
  echo "[WARN] Topic name mismatch detected!"
  echo ""
  echo "The existing system topic has a different name than what the Bicep"
  echo "template expects. This means the subscriptions are being created on"
  echo "a topic that doesn't exist or can't be found."
  echo ""
  echo "Options to fix:"
  echo "  1. Delete the existing topic and redeploy:"
  echo "     az eventgrid system-topic delete --resource-group $RG --name \"$ACTUAL_TOPIC\" --yes"
  echo "     ./update-eventgrid.sh"
  echo ""
  echo "  2. Check if the subscriptions exist on the actual topic:"
  echo "     az eventgrid system-topic event-subscription list --resource-group $RG --system-topic-name \"$ACTUAL_TOPIC\""
fi
