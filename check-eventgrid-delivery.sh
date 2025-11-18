#!/bin/bash
# Check Event Grid event delivery status and function execution logs

set -e

RG="qualys-scanner-rg"
EVENT_GRID_TOPIC=$(az eventgrid system-topic list --resource-group $RG --query "[0].name" -o tsv)
FUNCTION_APP=$(az functionapp list --resource-group $RG --query "[0].name" -o tsv)

echo "=== Event Grid System Topic ==="
az eventgrid system-topic show \
  --resource-group $RG \
  --name "$EVENT_GRID_TOPIC" \
  --query "{Name:name, ProvisioningState:provisioningState, Source:source}" \
  --output table

echo ""
echo "=== Event Grid Subscriptions Details ==="
az eventgrid system-topic event-subscription list \
  --resource-group $RG \
  --system-topic-name "$EVENT_GRID_TOPIC" \
  --output json | jq -r '.[] | {
    name: .name,
    provisioningState: .provisioningState,
    endpoint: .destination.resourceId,
    filter: .filter.advancedFilters
  }'

echo ""
echo "=== Checking Event Grid delivery metrics (last hour) ==="
TOPIC_ID=$(az eventgrid system-topic show \
  --resource-group $RG \
  --name "$EVENT_GRID_TOPIC" \
  --query "id" -o tsv)

# Get metrics for the last hour
az monitor metrics list \
  --resource "$TOPIC_ID" \
  --metric "PublishSuccessCount,PublishFailCount,DeliverySuccessCount,DeliveryAttemptFailCount,MatchedEventCount" \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ) \
  --interval PT1M \
  --aggregation Total \
  --output table 2>/dev/null || echo "Could not retrieve metrics"

echo ""
echo "=== Checking Application Insights for function executions ==="
APP_INSIGHTS=$(az monitor app-insights component list \
  --resource-group $RG \
  --query "[0].name" -o tsv 2>/dev/null || echo "")

if [ -n "$APP_INSIGHTS" ]; then
  echo "Application Insights: $APP_INSIGHTS"
  echo ""

  echo "Function invocations in last hour:"
  az monitor app-insights query \
    --app "$APP_INSIGHTS" \
    --resource-group $RG \
    --analytics-query "requests
      | where timestamp > ago(1h)
      | where name contains 'EventProcessor' or name contains 'HttpTest'
      | project timestamp, name, success, resultCode, duration, operation_Id
      | order by timestamp desc" \
    --output table 2>/dev/null || echo "No invocations found or query failed"

  echo ""
  echo "Function traces/logs in last hour:"
  az monitor app-insights query \
    --app "$APP_INSIGHTS" \
    --resource-group $RG \
    --analytics-query "traces
      | where timestamp > ago(1h)
      | where message contains 'EventProcessor' or message contains 'EventGrid' or severityLevel >= 2
      | project timestamp, severityLevel, message, operation_Id
      | order by timestamp desc
      | take 20" \
    --output table 2>/dev/null || echo "No traces found or query failed"

  echo ""
  echo "Exceptions in last hour:"
  az monitor app-insights query \
    --app "$APP_INSIGHTS" \
    --resource-group $RG \
    --analytics-query "exceptions
      | where timestamp > ago(1h)
      | project timestamp, type, outerMessage, problemId
      | order by timestamp desc
      | take 10" \
    --output table 2>/dev/null || echo "No exceptions found"
else
  echo "Application Insights not found - cannot query execution logs"
fi

echo ""
echo "=== Checking function app status and configuration ==="
az functionapp show \
  --resource-group $RG \
  --name $FUNCTION_APP \
  --query "{Name:name, State:state, HostNames:hostNames, Kind:kind, RuntimeVersion:siteConfig.linuxFxVersion}" \
  --output json

echo ""
echo "=== Listing deployed functions ==="
az functionapp function list \
  --resource-group $RG \
  --name $FUNCTION_APP \
  --query "[].{Name:name, TriggerType:config.bindings[0].type}" \
  --output table

echo ""
echo "=== Getting EventProcessor function details ==="
az functionapp function show \
  --resource-group $RG \
  --name $FUNCTION_APP \
  --function-name EventProcessor \
  --query "{Name:name, InvokeUrl:invokeUrlTemplate, Config:config}" \
  --output json 2>/dev/null || echo "EventProcessor function not found"

echo ""
echo "=== Testing if HttpTest function works ==="
HTTP_TEST_URL=$(az functionapp function show \
  --resource-group $RG \
  --name $FUNCTION_APP \
  --function-name HttpTest \
  --query "invokeUrlTemplate" -o tsv 2>/dev/null || echo "")

if [ -n "$HTTP_TEST_URL" ]; then
  echo "Calling: $HTTP_TEST_URL"
  curl -s "$HTTP_TEST_URL"
  echo ""
else
  echo "HttpTest function not found"
fi
