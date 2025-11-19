#!/bin/bash
# Check and display Event Grid subscription status
set -e

RG="${RESOURCE_GROUP:-qualys-scanner-rg}"

echo "========================================="
echo "Checking Event Grid Configuration"
echo "========================================="
echo ""

# Check if system topic exists
echo "[1/3] Checking Event Grid System Topic..."
TOPIC_NAME=$(az eventgrid system-topic list --resource-group "$RG" --query "[0].name" -o tsv 2>/dev/null || echo "")
if [ -z "$TOPIC_NAME" ]; then
  echo "  ❌ No Event Grid system topic found"
  echo "     Event Grid was never deployed"
else
  echo "  ✓ System Topic: $TOPIC_NAME"
fi

echo ""
echo "[2/3] Checking Event Grid Subscriptions..."
if [ -n "$TOPIC_NAME" ]; then
  # Check for our specific subscriptions
  ACI_SUB=$(az eventgrid system-topic event-subscription show \
    --resource-group "$RG" \
    --system-topic-name "$TOPIC_NAME" \
    --name "qualys-aci-container-deployments" \
    --query "name" -o tsv 2>/dev/null || echo "")

  ACA_SUB=$(az eventgrid system-topic event-subscription show \
    --resource-group "$RG" \
    --system-topic-name "$TOPIC_NAME" \
    --name "qualys-aca-container-deployments" \
    --query "name" -o tsv 2>/dev/null || echo "")

  if [ -n "$ACI_SUB" ]; then
    echo "  ✓ ACI subscription: $ACI_SUB"
  else
    echo "  ❌ ACI subscription not found (qualys-aci-container-deployments)"
  fi

  if [ -n "$ACA_SUB" ]; then
    echo "  ✓ ACA subscription: $ACA_SUB"
  else
    echo "  ❌ ACA subscription not found (qualys-aca-container-deployments)"
  fi

  # Show all subscriptions for reference
  echo ""
  echo "  All Event Grid subscriptions:"
  az eventgrid system-topic event-subscription list \
    --resource-group "$RG" \
    --system-topic-name "$TOPIC_NAME" \
    --query "[].{Name:name,State:provisioningState,Endpoint:destination.endpointType}" -o table 2>/dev/null || echo "    None"
else
  echo "  ⚠ Skipped (no system topic)"
  ACI_SUB=""
  ACA_SUB=""
fi

echo ""
echo "[3/3] Checking Function App..."
FUNC_NAME=$(az functionapp list --resource-group "$RG" --query "[0].name" -o tsv 2>/dev/null || echo "")
if [ -n "$FUNC_NAME" ]; then
  echo "  ✓ Function App: $FUNC_NAME"

  # Check if functions are deployed
  FUNCS=$(az functionapp function list --resource-group "$RG" --name "$FUNC_NAME" --query "[].name" -o tsv 2>/dev/null || echo "")
  if [ -n "$FUNCS" ]; then
    echo "  ✓ Deployed Functions:"
    for func in $FUNCS; do
      echo "    - $func"
    done
  else
    echo "  ⚠ No functions found in function app"
    echo "    Run: cd function_app && func azure functionapp publish $FUNC_NAME --python --build remote"
  fi
else
  echo "  ❌ No function app found"
fi

echo ""
echo "========================================="
echo "Summary"
echo "========================================="

if [ -z "$ACI_SUB" ] && [ -z "$ACA_SUB" ]; then
  echo ""
  echo "❌ CONTAINER SCANNER EVENT GRID SUBSCRIPTIONS ARE MISSING"
  echo ""
  echo "This is why your function is not being triggered!"
  echo "The system topic exists, but the container monitoring subscriptions don't."
  echo ""
  echo "To fix this, run:"
  echo "  export QUALYS_ACCESS_TOKEN='your-token-here'"
  echo "  export QUALYS_POD='US2'  # or your POD"
  echo "  ./update-eventgrid.sh"
  echo ""
else
  echo ""
  echo "✓ Event Grid container scanner subscriptions are configured"
  echo ""
  echo "If scans still aren't triggering, check:"
  echo "  1. Function logs: func azure functionapp logstream $FUNC_NAME"
  echo "  2. Event Grid delivery failures in Azure Portal"
  echo ""
fi
