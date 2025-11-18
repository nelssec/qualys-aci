#!/bin/bash
# Check Event Grid configuration

set -e

RG="${RESOURCE_GROUP:-qualys-scanner-rg}"

echo "Checking Event Grid Setup"
echo "========================="
echo ""

# Check if system topic exists
echo "1. Event Grid System Topic:"
SYSTEM_TOPIC=$(az eventgrid system-topic list \
  --resource-group "$RG" \
  --query "[0].{Name:name, ProvisioningState:provisioningState, Source:source}" \
  -o table)
echo "$SYSTEM_TOPIC"
echo ""

# Get system topic name
TOPIC_NAME=$(az eventgrid system-topic list \
  --resource-group "$RG" \
  --query "[0].name" -o tsv)

if [ -z "$TOPIC_NAME" ]; then
  echo "ERROR: No Event Grid system topic found"
  echo "Run: ./resume-deployment.sh"
  exit 1
fi

echo "2. Event Grid Subscriptions:"
az eventgrid system-topic event-subscription list \
  --resource-group "$RG" \
  --system-topic-name "$TOPIC_NAME" \
  --query "[].{Name:name, ProvisioningState:provisioningState, Endpoint:destination.endpointType}" \
  -o table
echo ""

# Check function app endpoint
FUNCTION_APP=$(az functionapp list --resource-group "$RG" --query "[0].name" -o tsv)
FUNCTION_ID=$(az functionapp show --resource-group "$RG" --name "$FUNCTION_APP" --query "id" -o tsv)
echo "3. Function App:"
echo "   Name: $FUNCTION_APP"
echo "   ID: $FUNCTION_ID"
echo ""

# Check if EventProcessor function exists
echo "4. EventProcessor Function:"
az functionapp function show \
  --resource-group "$RG" \
  --name "$FUNCTION_APP" \
  --function-name "EventProcessor" \
  --query "{Name:name, TriggerType:config.bindings[0].type, Direction:config.bindings[0].direction}" \
  -o table 2>/dev/null || echo "   ERROR: EventProcessor function not found"
echo ""

# Get recent invocations
echo "5. Recent Function Invocations (last 30 minutes):"
APP_INSIGHTS_ID=$(az monitor app-insights component list \
  --resource-group "$RG" \
  --query "[0].appId" -o tsv 2>/dev/null || echo "")

if [ -n "$APP_INSIGHTS_ID" ]; then
  az monitor app-insights query \
    --app "$APP_INSIGHTS_ID" \
    --analytics-query "requests
      | where timestamp > ago(30m)
      | where name == 'EventProcessor'
      | project timestamp, name, success, resultCode
      | order by timestamp desc
      | take 10" \
    --output table
else
  echo "   ERROR: Cannot query Application Insights"
fi
echo ""

# Check for any recent traces
echo "6. Recent Event Grid Events (last 30 minutes):"
if [ -n "$APP_INSIGHTS_ID" ]; then
  az monitor app-insights query \
    --app "$APP_INSIGHTS_ID" \
    --analytics-query "traces
      | where timestamp > ago(30m)
      | where message contains 'EVENT GRID EVENT RECEIVED'
      | project timestamp, message
      | order by timestamp desc
      | take 5" \
    --output table
else
  echo "   ERROR: Cannot query Application Insights"
fi
echo ""

echo "7. Event Grid Delivery Status:"
for SUB in $(az eventgrid system-topic event-subscription list \
  --resource-group "$RG" \
  --system-topic-name "$TOPIC_NAME" \
  --query "[].name" -o tsv); do
  echo "   Subscription: $SUB"
  az eventgrid system-topic event-subscription show \
    --resource-group "$RG" \
    --system-topic-name "$TOPIC_NAME" \
    --name "$SUB" \
    --query "{ProvisioningState:provisioningState, Endpoint:destination.endpointUrl}" \
    -o json
  echo ""
done
