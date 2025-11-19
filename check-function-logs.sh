#!/bin/bash
# Check Application Insights for recent function invocations
set -e

RG="${RESOURCE_GROUP:-qualys-scanner-rg}"

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

echo "[1/2] Checking recent function invocations (last 1 hour)..."
az monitor app-insights query \
  --app "$APP_ID" \
  --analytics-query "requests | where timestamp > ago(1h) and operation_Name == 'EventProcessor' | summarize count()" \
  2>/dev/null | grep -A 5 "rows" || echo "No invocations found"

echo ""
echo "[2/2] Checking Event Grid events in traces (last 1 hour)..."
az monitor app-insights query \
  --app "$APP_ID" \
  --analytics-query "traces | where timestamp > ago(1h) and message contains 'EVENT GRID' | summarize count()" \
  2>/dev/null | grep -A 5 "rows" || echo "No Event Grid events found"

echo ""
echo "========================================="
echo "Detailed Logs"
echo "========================================="
echo ""
echo "To view detailed logs in Azure Portal:"
echo "  1. Go to: https://portal.azure.com"
echo "  2. Navigate to: Function App -> qscan-alol3ziwapdfm -> Monitor"
echo "  3. Or Application Insights -> $APP_INSIGHTS -> Logs"
echo ""
echo "To query manually:"
echo "  az monitor app-insights query --app $APP_ID --analytics-query \"requests | where timestamp > ago(1h)\""
echo ""
