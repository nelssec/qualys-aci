#!/bin/bash
# Check Application Insights for recent function invocations
set -e

RG="${RESOURCE_GROUP:-qualys-scanner-rg}"
CONTAINER_NAME="${1:-}"

echo "========================================="
echo "Function Invocation Logs"
echo "========================================="
echo ""

# Get Application Insights resource
APP_INSIGHTS=$(az monitor app-insights component list --resource-group "$RG" --query "[0].name" -o tsv 2>/dev/null)
APP_ID=$(az monitor app-insights component list --resource-group "$RG" --query "[0].appId" -o tsv 2>/dev/null)

if [ -z "$APP_INSIGHTS" ]; then
  echo "[ERROR] No Application Insights resource found"
  exit 1
fi

echo "Application Insights: $APP_INSIGHTS"
echo ""

echo "[1/3] Recent function invocations (last 30 minutes)..."
az monitor app-insights query \
  --app "$APP_ID" \
  --analytics-query "requests | where timestamp > ago(30m) | where operation_Name == 'EventProcessor' | project timestamp, resultCode, duration, name | order by timestamp desc | take 10" \
  --output table

echo ""
echo "[2/3] Recent Event Grid events received (last 30 minutes)..."
az monitor app-insights query \
  --app "$APP_ID" \
  --analytics-query "traces | where timestamp > ago(30m) | where message contains 'EVENT GRID EVENT RECEIVED' | project timestamp, message | order by timestamp desc | take 10" \
  --output table

echo ""
echo "[3/3] Recent errors (last 30 minutes)..."
az monitor app-insights query \
  --app "$APP_ID" \
  --analytics-query "traces | where timestamp > ago(30m) | where severityLevel >= 3 | project timestamp, severityLevel, message | order by timestamp desc | take 10" \
  --output table

echo ""
echo "========================================="
echo "Summary"
echo "========================================="

INVOCATION_COUNT=$(az monitor app-insights query \
  --app "$APP_ID" \
  --analytics-query "requests | where timestamp > ago(30m) | where operation_Name == 'EventProcessor' | count" \
  --output tsv --query "tables[0].rows[0][0]" 2>/dev/null || echo "0")

echo ""
echo "Total EventProcessor invocations in last 30 minutes: $INVOCATION_COUNT"

if [ "$INVOCATION_COUNT" = "0" ]; then
  echo ""
  echo "[WARN] No function invocations detected"
  echo ""
  echo "Possible issues:"
  echo "  1. Event Grid propagation delay (can take 1-2 minutes)"
  echo "  2. Event Grid subscription not enabled properly"
  echo "  3. Function not receiving events due to configuration issue"
  echo ""
  echo "Wait 2 minutes and run this script again:"
  echo "  ./check-function-logs.sh"
else
  echo ""
  echo "[OK] Function is being triggered by Event Grid"
fi
echo ""
