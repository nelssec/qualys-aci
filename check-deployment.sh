#!/bin/bash
# Check deployment status and provide guidance

set -e

RG="${RESOURCE_GROUP:-qualys-scanner-rg}"

echo "Checking deployment status..."
echo ""

# Check if resource group exists
if az group show --name "$RG" &>/dev/null; then
  echo "Resource group exists: $RG"

  # Check for function app
  FUNCTION_APP=$(az functionapp list --resource-group "$RG" --query "[0].name" -o tsv 2>/dev/null || echo "")
  if [ -n "$FUNCTION_APP" ]; then
    echo "Function App found: $FUNCTION_APP"
  fi

  # Check for Event Grid
  EVENT_GRID_TOPIC=$(az eventgrid system-topic list --resource-group "$RG" --query "[0].name" -o tsv 2>/dev/null || echo "")
  if [ -n "$EVENT_GRID_TOPIC" ]; then
    echo "Event Grid Topic found: $EVENT_GRID_TOPIC"

    SUBSCRIPTIONS=$(az eventgrid system-topic event-subscription list \
      --resource-group "$RG" \
      --system-topic-name "$EVENT_GRID_TOPIC" \
      --query "length([])" -o tsv 2>/dev/null || echo "0")
    echo "Event Grid Subscriptions: $SUBSCRIPTIONS"
  fi

  echo ""
  echo "Options:"
  echo "1. Delete and redeploy:"
  echo "   az group delete --name $RG --yes"
  echo "   ./deploy.sh"
  echo ""
  echo "2. Update existing deployment:"
  echo "   ./update.sh"

else
  echo "Resource group does not exist: $RG"
  echo "Run: ./deploy.sh"
fi
