#!/bin/bash
# Cleanup old containers and diagnose Event Grid trigger issues

set -e

RG="qualys-scanner-rg"
FUNCTION_APP=$(az functionapp list --resource-group $RG --query "[0].name" -o tsv)

echo "=== Current containers in resource group ==="
az container list --resource-group $RG --query "[].{Name:name, Status:instanceView.state, Image:containers[0].image}" --output table

echo ""
echo "=== Cleaning up old test containers ==="
TEST_CONTAINERS=$(az container list --resource-group $RG --query "[?starts_with(name, 'test-')].name" -o tsv)
if [ -n "$TEST_CONTAINERS" ]; then
  for container in $TEST_CONTAINERS; do
    echo "Deleting $container..."
    az container delete --resource-group $RG --name "$container" --yes
  done
else
  echo "No test containers to clean up"
fi

echo ""
echo "=== Cleaning up old qscanner containers ==="
QSCANNER_CONTAINERS=$(az container list --resource-group $RG --query "[?starts_with(name, 'qscanner-')].name" -o tsv)
if [ -n "$QSCANNER_CONTAINERS" ]; then
  for container in $QSCANNER_CONTAINERS; do
    echo "Deleting $container..."
    az container delete --resource-group $RG --name "$container" --yes
  done
else
  echo "No qscanner containers to clean up"
fi

echo ""
echo "=== Checking Event Grid subscriptions ==="
az eventgrid system-topic event-subscription list \
  --resource-group $RG \
  --system-topic-name qualys-scanner-events \
  --query "[].{Name:name, ProvisioningState:provisioningState, Endpoint:destination.endpointType}" \
  --output table

echo ""
echo "=== Checking function app settings ==="
az functionapp config appsettings list \
  --resource-group $RG \
  --name $FUNCTION_APP \
  --query "[?starts_with(name, 'QUALYS_') || name=='AZURE_SUBSCRIPTION_ID' || name=='RESOURCE_GROUP'].{Name:name, Value:value}" \
  --output table

echo ""
echo "=== Checking recent function logs ==="
az functionapp log tail \
  --resource-group $RG \
  --name $FUNCTION_APP &

LOG_PID=$!
sleep 5
kill $LOG_PID 2>/dev/null || true

echo ""
echo ""
echo "=== Deploying new test container to trigger Event Grid ==="
TEST_NAME="test-scan-$(date +%s)"
az container create \
  --resource-group $RG \
  --name $TEST_NAME \
  --image mcr.microsoft.com/azuredocs/aci-helloworld:latest \
  --os-type Linux \
  --cpu 1 \
  --memory 1 \
  --restart-policy Never \
  --no-wait

echo ""
echo "Waiting 45 seconds for Event Grid to process and function to trigger..."
sleep 45

echo ""
echo "=== Checking if qscanner container was created ==="
az container list \
  --resource-group $RG \
  --query "[?starts_with(name, 'qscanner-')].{Name:name, Status:instanceView.state, Created:containers[0].instanceView.currentState.startTime}" \
  --output table

QSCANNER=$(az container list --resource-group $RG --query "[?starts_with(name, 'qscanner-')].name | [0]" -o tsv)
if [ -n "$QSCANNER" ]; then
  echo ""
  echo "=== QScanner container logs ==="
  az container logs --resource-group $RG --name "$QSCANNER"
else
  echo ""
  echo "No qscanner container found. Checking function invocations..."
  az monitor app-insights query \
    --app $(az functionapp show --resource-group $RG --name $FUNCTION_APP --query "appInsightsId" -o tsv 2>/dev/null || echo "NOT_FOUND") \
    --analytics-query "traces | where timestamp > ago(5m) | where message contains 'EventProcessor' | order by timestamp desc | take 20" \
    --offset 5m 2>/dev/null || echo "Application Insights not available or query failed"
fi
