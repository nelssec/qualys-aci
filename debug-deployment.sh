#!/bin/bash
# Debug script to check Event Grid and Function App configuration

set -e

RG="${RESOURCE_GROUP:-qualys-scanner-rg}"

echo "========================================="
echo "Qualys Scanner Deployment Diagnostics"
echo "========================================="
echo ""

# 1. Check Function App exists and is running
echo "[1/6] Checking Function App..."
FUNCTION_APP=$(az functionapp list --resource-group "$RG" --query "[0].name" -o tsv 2>/dev/null)

if [ -z "$FUNCTION_APP" ]; then
  echo "❌ ERROR: No function app found in resource group $RG"
  exit 1
fi

STATE=$(az functionapp show --resource-group "$RG" --name "$FUNCTION_APP" --query "state" -o tsv)
echo "  Function App: $FUNCTION_APP"
echo "  State: $STATE"

if [ "$STATE" != "Running" ]; then
  echo "  ❌ Function app is not running!"
else
  echo "  ✓ Function app is running"
fi
echo ""

# 2. Check if functions are deployed
echo "[2/6] Checking deployed functions..."
FUNCTIONS=$(az functionapp function list --resource-group "$RG" --name "$FUNCTION_APP" --query "[].name" -o tsv 2>/dev/null)

if [ -z "$FUNCTIONS" ]; then
  echo "  ❌ ERROR: No functions found in function app!"
  echo "  Run: cd function_app && func azure functionapp publish $FUNCTION_APP --python --build remote"
else
  echo "  Functions deployed:"
  for func in $FUNCTIONS; do
    echo "    - $func"
  done
  echo "  ✓ Functions are deployed"
fi
echo ""

# 3. Check Event Grid system topic
echo "[3/6] Checking Event Grid system topic..."
TOPIC_NAME=$(az eventgrid system-topic list --resource-group "$RG" --query "[0].name" -o tsv 2>/dev/null)

if [ -z "$TOPIC_NAME" ]; then
  echo "  ❌ ERROR: No Event Grid system topic found!"
  echo "  Run: az deployment sub create --parameters enableEventGrid=true ..."
else
  TOPIC_STATE=$(az eventgrid system-topic show --resource-group "$RG" --name "$TOPIC_NAME" --query "provisioningState" -o tsv)
  echo "  Topic: $TOPIC_NAME"
  echo "  State: $TOPIC_STATE"

  if [ "$TOPIC_STATE" = "Succeeded" ]; then
    echo "  ✓ Event Grid topic is ready"
  else
    echo "  ❌ Event Grid topic is not ready: $TOPIC_STATE"
  fi
fi
echo ""

# 4. Check Event Grid subscriptions
echo "[4/6] Checking Event Grid subscriptions..."
if [ ! -z "$TOPIC_NAME" ]; then
  SUBSCRIPTIONS=$(az eventgrid system-topic event-subscription list \
    --resource-group "$RG" \
    --system-topic-name "$TOPIC_NAME" \
    --query "[].{Name:name,State:provisioningState,Endpoint:destination.endpointType}" \
    -o table)

  if [ -z "$SUBSCRIPTIONS" ]; then
    echo "  ❌ ERROR: No Event Grid subscriptions found!"
    echo "  Run: az deployment sub create --parameters enableEventGrid=true ..."
  else
    echo "$SUBSCRIPTIONS"

    SUB_COUNT=$(az eventgrid system-topic event-subscription list \
      --resource-group "$RG" \
      --system-topic-name "$TOPIC_NAME" \
      --query "length(@)" -o tsv)

    SUCCEEDED_COUNT=$(az eventgrid system-topic event-subscription list \
      --resource-group "$RG" \
      --system-topic-name "$TOPIC_NAME" \
      --query "[?provisioningState=='Succeeded'] | length(@)" -o tsv)

    if [ "$SUB_COUNT" -eq 2 ] && [ "$SUCCEEDED_COUNT" -eq 2 ]; then
      echo "  ✓ Event Grid subscriptions are configured ($SUCCEEDED_COUNT/2)"
    else
      echo "  ⚠ Expected 2 subscriptions, found: $SUB_COUNT succeeded, $SUCCEEDED_COUNT total"
    fi
  fi
else
  echo "  ⚠ Skipping (no topic found)"
fi
echo ""

# 5. Check function app configuration
echo "[5/6] Checking Function App configuration..."
SETTINGS=$(az functionapp config appsettings list \
  --resource-group "$RG" \
  --name "$FUNCTION_APP" \
  --query "[?starts_with(name, 'QUALYS_') || name=='AZURE_SUBSCRIPTION_ID' || name=='STORAGE_CONNECTION_STRING'].{Name:name,Value:value}" \
  -o table)

echo "$SETTINGS"
echo ""

# Check critical settings
QUALYS_POD=$(az functionapp config appsettings list \
  --resource-group "$RG" \
  --name "$FUNCTION_APP" \
  --query "[?name=='QUALYS_POD'].value" -o tsv)

QUALYS_TOKEN=$(az functionapp config appsettings list \
  --resource-group "$RG" \
  --name "$FUNCTION_APP" \
  --query "[?name=='QUALYS_ACCESS_TOKEN'].value" -o tsv)

if [ -z "$QUALYS_POD" ]; then
  echo "  ❌ QUALYS_POD not configured"
else
  echo "  ✓ QUALYS_POD: $QUALYS_POD"
fi

if [ -z "$QUALYS_TOKEN" ]; then
  echo "  ❌ QUALYS_ACCESS_TOKEN not configured"
else
  echo "  ✓ QUALYS_ACCESS_TOKEN: configured (hidden)"
fi
echo ""

# 6. Check recent function invocations
echo "[6/6] Checking recent function invocations..."
echo "  Checking Application Insights for recent executions..."

APP_INSIGHTS_ID=$(az monitor app-insights component list \
  --resource-group "$RG" \
  --query "[0].appId" -o tsv 2>/dev/null)

if [ ! -z "$APP_INSIGHTS_ID" ]; then
  RECENT_INVOCATIONS=$(az monitor app-insights query \
    --app "$APP_INSIGHTS_ID" \
    --analytics-query "traces | where timestamp > ago(1h) | where operation_Name == 'EventProcessor' | summarize count()" \
    --offset 1h \
    --query "tables[0].rows[0][0]" -o tsv 2>/dev/null || echo "0")

  echo "  Function invocations (last hour): $RECENT_INVOCATIONS"

  if [ "$RECENT_INVOCATIONS" = "0" ]; then
    echo "  ⚠ No function invocations detected"
  else
    echo "  ✓ Function has been invoked"
  fi
else
  echo "  ⚠ Application Insights not found, skipping"
fi
echo ""

# Summary
echo "========================================="
echo "Summary"
echo "========================================="
echo ""

if [ "$STATE" = "Running" ] && [ ! -z "$FUNCTIONS" ] && [ ! -z "$TOPIC_NAME" ] && [ "$SUCCEEDED_COUNT" -eq 2 ]; then
  echo "✓ All critical components are configured correctly"
  echo ""
  echo "If scans are still not working, check:"
  echo "  1. Wait 2-3 minutes for Event Grid propagation"
  echo "  2. View function logs: func azure functionapp logstream $FUNCTION_APP"
  echo "  3. Check Application Insights for errors"
  echo "  4. Verify Event Grid is sending events: Azure Portal > Event Grid > Metrics"
else
  echo "⚠ Configuration issues detected. Please review the output above."
  echo ""
  echo "Common fixes:"
  echo "  - Deploy function code: cd function_app && func azure functionapp publish $FUNCTION_APP --python --build remote"
  echo "  - Enable Event Grid: ./deploy.sh (step 3)"
  echo "  - Check Azure Portal for detailed errors"
fi
echo ""
