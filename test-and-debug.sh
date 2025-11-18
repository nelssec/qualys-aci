#!/bin/bash
# Comprehensive test and debug script for Qualys ACI scanner

set -e

RG="qualys-scanner-rg"
FUNCTION_APP=$(az functionapp list --resource-group $RG --query "[0].name" -o tsv)
EVENT_GRID_TOPIC=$(az eventgrid system-topic list --resource-group $RG --query "[0].name" -o tsv)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "========================================"
echo "  Qualys ACI Scanner - Test & Debug"
echo "========================================"
echo ""

# 1. Check Environment Variables
echo "=== 1. Checking Required Environment Variables ==="
REQUIRED_VARS=("QUALYS_ACCESS_TOKEN" "QUALYS_POD" "AZURE_SUBSCRIPTION_ID" "QSCANNER_RESOURCE_GROUP" "STORAGE_CONNECTION_STRING" "QSCANNER_IMAGE")
MISSING_VARS=()

for var in "${REQUIRED_VARS[@]}"; do
  VALUE=$(az functionapp config appsettings list \
    --resource-group $RG \
    --name $FUNCTION_APP \
    --query "[?name=='$var'].value" -o tsv 2>/dev/null)

  if [ -z "$VALUE" ]; then
    echo -e "${RED}❌ $var: NOT SET${NC}"
    MISSING_VARS+=("$var")
  else
    if [[ "$var" == *"TOKEN"* ]] || [[ "$var" == *"CONNECTION_STRING"* ]]; then
      echo -e "${GREEN}✓ $var: ***configured***${NC}"
    else
      echo -e "${GREEN}✓ $var: $VALUE${NC}"
    fi
  fi
done

if [ ${#MISSING_VARS[@]} -gt 0 ]; then
  echo -e "${RED}ERROR: Missing required environment variables!${NC}"
  exit 1
fi

echo ""

# 2. Check Function Deployment
echo "=== 2. Verifying Function Deployment ==="
az functionapp function list \
  --resource-group $RG \
  --name $FUNCTION_APP \
  --query "[].{Name:name, TriggerType:config.bindings[0].type}" \
  --output table

echo ""
echo "Testing HttpTest endpoint..."
HTTP_TEST_URL=$(az functionapp function show \
  --resource-group $RG \
  --name $FUNCTION_APP \
  --function-name HttpTest \
  --query "invokeUrlTemplate" -o tsv 2>/dev/null || echo "")

if [ -n "$HTTP_TEST_URL" ]; then
  RESPONSE=$(curl -s "$HTTP_TEST_URL")
  echo "Response: $RESPONSE"
  echo -e "${GREEN}✓ Function runtime is healthy${NC}"
else
  echo -e "${RED}❌ HttpTest function not found${NC}"
fi

echo ""

# 3. Check Event Grid Configuration
echo "=== 3. Checking Event Grid Subscriptions ==="
az eventgrid system-topic event-subscription list \
  --resource-group $RG \
  --system-topic-name "$EVENT_GRID_TOPIC" \
  --query "[].{Name:name, State:provisioningState, Endpoint:destination.endpointType}" \
  --output table

echo ""

# 4. Check Application Insights
echo "=== 4. Checking Application Insights ==="
APP_INSIGHTS=$(az resource list \
  --resource-group $RG \
  --resource-type "microsoft.insights/components" \
  --query "[0].name" -o tsv 2>/dev/null || echo "")

if [ -n "$APP_INSIGHTS" ]; then
  echo "Found Application Insights: $APP_INSIGHTS"
  echo ""

  echo "Recent function invocations (last hour):"
  az monitor app-insights query \
    --app "$APP_INSIGHTS" \
    --resource-group $RG \
    --analytics-query "requests | where timestamp > ago(1h) | project timestamp, name, success, resultCode | order by timestamp desc | take 10" \
    --output table 2>/dev/null || echo "No invocations or query failed"

  echo ""
  echo "Recent errors (last hour):"
  az monitor app-insights query \
    --app "$APP_INSIGHTS" \
    --resource-group $RG \
    --analytics-query "traces | where timestamp > ago(1h) and severityLevel >= 3 | project timestamp, message | order by timestamp desc | take 10" \
    --output table 2>/dev/null || echo "No errors found"
else
  echo -e "${YELLOW}⚠ Application Insights not found${NC}"
fi

echo ""

# 5. List Current Containers
echo "=== 5. Current Containers in Resource Group ==="
CONTAINERS=$(az container list --resource-group $RG --query "[].{Name:name, State:instanceView.state, Image:containers[0].image}" --output table)
if [ -n "$CONTAINERS" ]; then
  echo "$CONTAINERS"
else
  echo "No containers found"
fi

echo ""

# 6. Deploy Test Container
echo "=== 6. Deploying Test Container ==="
TEST_NAME="test-debug-$(date +%s)"
echo "Container name: $TEST_NAME"

az container create \
  --resource-group $RG \
  --name $TEST_NAME \
  --image mcr.microsoft.com/azuredocs/aci-helloworld:latest \
  --os-type Linux \
  --cpu 1 \
  --memory 1 \
  --restart-policy Never \
  --output none

echo -e "${GREEN}✓ Test container deployed${NC}"
echo ""
echo "Waiting 60 seconds for Event Grid to trigger function..."

# Stream logs in background
(
  sleep 30
  echo ""
  echo "=== Streaming function logs (30 sec sample) ==="
  timeout 30s az webapp log tail --resource-group $RG --name $FUNCTION_APP 2>&1 | grep -i "event\|error\|process" || echo "No relevant logs"
) &

sleep 60

echo ""

# 7. Check for QScanner Container
echo "=== 7. Checking for QScanner Container ==="
QSCANNER_CONTAINERS=$(az container list \
  --resource-group $RG \
  --query "[?starts_with(name, 'qscanner-')].{Name:name, State:instanceView.state, Created:containers[0].instanceView.currentState.startTime}" \
  --output table)

if [ -n "$QSCANNER_CONTAINERS" ] && [ "$QSCANNER_CONTAINERS" != "[]" ]; then
  echo -e "${GREEN}SUCCESS! QScanner container was created!${NC}"
  echo "$QSCANNER_CONTAINERS"

  QSCANNER_NAME=$(az container list --resource-group $RG --query "[?starts_with(name, 'qscanner-')].name | [0]" -o tsv)

  echo ""
  echo "=== QScanner Container Logs ==="
  az container logs --resource-group $RG --name "$QSCANNER_NAME" 2>&1 || echo "Logs not available yet"

  echo ""
  echo "=== QScanner Container Command ==="
  az container show \
    --resource-group $RG \
    --name "$QSCANNER_NAME" \
    --query "{Command:containers[0].command, Image:containers[0].image, ExitCode:containers[0].instanceView.currentState.exitCode}" \
    --output json
else
  echo -e "${RED}❌ No QScanner container found${NC}"
  echo ""
  echo "=== Troubleshooting ==="
  echo "Possible issues:"
  echo "1. Event Grid is not delivering events to the function"
  echo "2. Function is receiving events but failing (check Application Insights above)"
  echo "3. Function code has import errors or missing dependencies"
  echo "4. STORAGE_CONNECTION_STRING is invalid"
  echo ""
  echo "Next steps:"
  echo "- Check Azure Portal > Function App > Monitor for invocation history"
  echo "- Check Azure Portal > Event Grid System Topic > Metrics for delivery status"
  echo "- Enable Application Insights if not already enabled"
  echo "- Check function app logs above for any errors during the 30-second window"
fi

echo ""
echo "========================================"
echo "  Test Complete"
echo "========================================"
