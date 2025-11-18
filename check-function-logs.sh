#!/bin/bash
# Check function logs directly from the filesystem

set -e

RG="qualys-scanner-rg"
FUNCTION_APP=$(az functionapp list --resource-group $RG --query "[0].name" -o tsv)

echo "=== Checking if Application Insights is configured ==="
APP_INSIGHTS_KEY=$(az functionapp config appsettings list \
  --resource-group $RG \
  --name $FUNCTION_APP \
  --query "[?name=='APPINSIGHTS_INSTRUMENTATIONKEY' || name=='APPLICATIONINSIGHTS_CONNECTION_STRING'].{Name:name, Value:value}" \
  --output table)

echo "$APP_INSIGHTS_KEY"
echo ""

echo "=== Finding Application Insights resource ==="
APP_INSIGHTS=$(az resource list \
  --resource-group $RG \
  --resource-type "microsoft.insights/components" \
  --query "[0].name" -o tsv)

if [ -n "$APP_INSIGHTS" ]; then
  echo "Found Application Insights: $APP_INSIGHTS"
  APP_ID=$(az monitor app-insights component show \
    --resource-group $RG \
    --app "$APP_INSIGHTS" \
    --query "appId" -o tsv)
  echo "App ID: $APP_ID"
  echo ""

  echo "=== Querying traces from last 2 hours ==="
  az monitor app-insights query \
    --app "$APP_INSIGHTS" \
    --resource-group $RG \
    --analytics-query "traces | where timestamp > ago(2h) | project timestamp, message, severityLevel | order by timestamp desc | take 50" \
    --output table 2>&1

  echo ""
  echo "=== Querying requests from last 2 hours ==="
  az monitor app-insights query \
    --app "$APP_INSIGHTS" \
    --resource-group $RG \
    --analytics-query "requests | where timestamp > ago(2h) | project timestamp, name, success, resultCode | order by timestamp desc | take 20" \
    --output table 2>&1

  echo ""
  echo "=== Querying exceptions from last 2 hours ==="
  az monitor app-insights query \
    --app "$APP_INSIGHTS" \
    --resource-group $RG \
    --analytics-query "exceptions | where timestamp > ago(2h) | project timestamp, type, outerMessage | order by timestamp desc | take 10" \
    --output table 2>&1
else
  echo "No Application Insights found!"
  echo ""
  echo "=== Checking all resources in resource group ==="
  az resource list --resource-group $RG --query "[].{Name:name, Type:type}" --output table
fi

echo ""
echo "=== Streaming function logs (press Ctrl+C to stop) ==="
echo "Starting log stream for 10 seconds..."
timeout 10s az webapp log tail --resource-group $RG --name $FUNCTION_APP 2>&1 || echo "Log stream timeout or no logs"
