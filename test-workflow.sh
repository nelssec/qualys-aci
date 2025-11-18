#!/bin/bash
# Test the complete Event Grid -> Function -> QScanner workflow

set -e

RG="qualys-scanner-rg"
FUNCTION_APP=$(az functionapp list --resource-group $RG --query "[0].name" -o tsv)

echo "=== Checking Event Grid subscriptions status ==="
EVENT_GRID_TOPIC=$(az eventgrid system-topic list --resource-group $RG --query "[0].name" -o tsv)
az eventgrid system-topic event-subscription list \
  --resource-group $RG \
  --system-topic-name "$EVENT_GRID_TOPIC" \
  --query "[].{Name:name, State:provisioningState}" \
  --output table

echo ""
echo "=== Current containers before test ==="
az container list --resource-group $RG --query "[].name" -o table

echo ""
echo "=== Deploying test container to trigger Event Grid ==="
TEST_NAME="test-trigger-$(date +%s)"
echo "Container name: $TEST_NAME"

az container create \
  --resource-group $RG \
  --name $TEST_NAME \
  --image mcr.microsoft.com/azuredocs/aci-helloworld:latest \
  --os-type Linux \
  --cpu 1 \
  --memory 1 \
  --restart-policy Never

echo ""
echo "Test container deployed successfully!"
echo ""
echo "Waiting 60 seconds for Event Grid to trigger function and qscanner to start..."
sleep 60

echo ""
echo "=== Checking for qscanner containers ==="
QSCANNER_CONTAINERS=$(az container list \
  --resource-group $RG \
  --query "[?starts_with(name, 'qscanner-')].{Name:name, State:instanceView.state, StartTime:containers[0].instanceView.currentState.startTime}" \
  --output table)

if [ -n "$QSCANNER_CONTAINERS" ]; then
  echo "$QSCANNER_CONTAINERS"
  echo ""
  echo "SUCCESS! QScanner container was created!"
  echo ""

  # Get the qscanner container name
  QSCANNER_NAME=$(az container list \
    --resource-group $RG \
    --query "[?starts_with(name, 'qscanner-')].name | [0]" -o tsv)

  echo "=== QScanner container logs ==="
  az container logs --resource-group $RG --name "$QSCANNER_NAME" || echo "Logs not available yet"

  echo ""
  echo "=== QScanner container details ==="
  az container show \
    --resource-group $RG \
    --name "$QSCANNER_NAME" \
    --query "{Name:name, State:instanceView.state, Command:containers[0].command, Image:containers[0].image, ExitCode:containers[0].instanceView.currentState.exitCode}" \
    --output json
else
  echo "No qscanner containers found!"
  echo ""
  echo "=== Troubleshooting: Checking function execution history ==="

  # Try to get function execution logs from Application Insights
  APP_INSIGHTS=$(az monitor app-insights component list \
    --resource-group $RG \
    --query "[0].name" -o tsv 2>/dev/null || echo "")

  if [ -n "$APP_INSIGHTS" ]; then
    echo "Querying Application Insights for EventProcessor invocations..."
    az monitor app-insights query \
      --app "$APP_INSIGHTS" \
      --resource-group $RG \
      --analytics-query "requests | where timestamp > ago(5m) and name contains 'EventProcessor' | project timestamp, name, success, resultCode, duration" \
      --offset 5m 2>/dev/null || echo "Could not query Application Insights"

    echo ""
    echo "Checking for errors..."
    az monitor app-insights query \
      --app "$APP_INSIGHTS" \
      --resource-group $RG \
      --analytics-query "traces | where timestamp > ago(5m) and severityLevel >= 3 | project timestamp, severityLevel, message | order by timestamp desc | take 10" \
      --offset 5m 2>/dev/null || echo "Could not query Application Insights"
  else
    echo "Application Insights not found"
  fi

  echo ""
  echo "=== Checking function app status ==="
  az functionapp show \
    --resource-group $RG \
    --name $FUNCTION_APP \
    --query "{Name:name, State:state, DefaultHostName:defaultHostName}" \
    --output table

  echo ""
  echo "=== Manual trigger test - Invoke EventProcessor directly ==="
  echo "You can manually trigger the function to test if the code works:"
  echo "1. Get the test container details:"
  echo "   az container show --resource-group $RG --name $TEST_NAME"
  echo ""
  echo "2. Check Event Grid delivery status:"
  echo "   az eventgrid system-topic event-subscription show \\"
  echo "     --resource-group $RG \\"
  echo "     --system-topic-name $EVENT_GRID_TOPIC \\"
  echo "     --name aci-container-deployments \\"
  echo "     --query '{Endpoint:destination, State:provisioningState}'"
fi

echo ""
echo "=== All containers in resource group ==="
az container list --resource-group $RG --query "[].{Name:name, State:instanceView.state, Image:containers[0].image}" --output table
