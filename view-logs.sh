#!/bin/bash
# View scan logs from Application Insights and Function App

set -e

RG="${RESOURCE_GROUP:-qualys-scanner-rg}"

echo "Fetching logs..."
echo ""

# Get Application Insights App ID (not name)
APP_ID=$(az monitor app-insights component list \
  --resource-group "$RG" \
  --query "[0].appId" -o tsv)

if [ -z "$APP_ID" ]; then
  echo "ERROR: Application Insights not found"
  exit 1
fi

echo "Application Insights App ID: $APP_ID"
echo ""

# Query last 30 minutes of EventProcessor logs
echo "Recent EventProcessor logs (last 30 minutes):"
az monitor app-insights query \
  --app "$APP_ID" \
  --analytics-query "traces
    | where timestamp > ago(30m)
    | where operation_Name == 'EventProcessor'
    | project timestamp, message, severityLevel
    | order by timestamp desc
    | take 50" \
  --output table

echo ""
echo "Recent QScanner scan logs (last 30 minutes):"
az monitor app-insights query \
  --app "$APP_ID" \
  --analytics-query "traces
    | where timestamp > ago(30m)
    | where message contains 'qscanner' or message contains 'scan'
    | project timestamp, message, severityLevel
    | order by timestamp desc
    | take 50" \
  --output table

echo ""
echo "Recent errors (last 30 minutes):"
az monitor app-insights query \
  --app "$APP_ID" \
  --analytics-query "traces
    | where timestamp > ago(30m)
    | where severityLevel >= 3
    | project timestamp, message, severityLevel
    | order by timestamp desc
    | take 20" \
  --output table

echo ""
echo "Alternative: View logs in Azure Portal"
FUNCTION_APP=$(az functionapp list --resource-group "$RG" --query "[0].name" -o tsv)
echo "Function App: https://portal.azure.com/#@/resource/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RG/providers/Microsoft.Web/sites/$FUNCTION_APP/logStream"
