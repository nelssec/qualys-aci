#!/bin/bash
# Check logs for the most recent scan attempt

set -e

RG="${RESOURCE_GROUP:-qualys-scanner-rg}"

echo "Checking Recent Scan Activity"
echo "============================="
echo ""

# Get Application Insights ID
APP_INSIGHTS_ID=$(az monitor app-insights component list \
  --resource-group "$RG" \
  --query "[0].appId" -o tsv 2>/dev/null || echo "")

if [ -z "$APP_INSIGHTS_ID" ]; then
  echo "ERROR: Cannot access Application Insights"
  exit 1
fi

echo "1. Recent EventProcessor invocations (last 10 minutes):"
az monitor app-insights query \
  --app "$APP_INSIGHTS_ID" \
  --analytics-query "requests
    | where timestamp > ago(10m)
    | where name == 'EventProcessor'
    | project timestamp, success, resultCode, duration
    | order by timestamp desc" \
  --output table
echo ""

echo "2. Recent Event Grid events received (last 10 minutes):"
az monitor app-insights query \
  --app "$APP_INSIGHTS_ID" \
  --analytics-query "traces
    | where timestamp > ago(10m)
    | where message contains 'EVENT GRID EVENT RECEIVED'
    | project timestamp
    | order by timestamp desc
    | take 5" \
  --output table
echo ""

echo "3. Container names processed (last 10 minutes):"
az monitor app-insights query \
  --app "$APP_INSIGHTS_ID" \
  --analytics-query "traces
    | where timestamp > ago(10m)
    | where message contains 'Container Name:'
    | project timestamp, message
    | order by timestamp desc
    | take 10" \
  --output table
echo ""

echo "4. Images found and scan decisions (last 10 minutes):"
az monitor app-insights query \
  --app "$APP_INSIGHTS_ID" \
  --analytics-query "traces
    | where timestamp > ago(10m)
    | where message contains 'image' or message contains 'scan'
    | project timestamp, message
    | order by timestamp desc
    | take 20" \
  --output table
echo ""

echo "5. Any errors (last 10 minutes):"
az monitor app-insights query \
  --app "$APP_INSIGHTS_ID" \
  --analytics-query "traces
    | where timestamp > ago(10m)
    | where severityLevel >= 3
    | project timestamp, severityLevel, message
    | order by timestamp desc
    | take 10" \
  --output table
echo ""

echo "6. QScanner container activity (last 10 minutes):"
az monitor app-insights query \
  --app "$APP_INSIGHTS_ID" \
  --analytics-query "traces
    | where timestamp > ago(10m)
    | where message contains 'qscanner' or message contains 'Creating ACI'
    | project timestamp, message
    | order by timestamp desc
    | take 10" \
  --output table
