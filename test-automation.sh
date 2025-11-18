#!/bin/bash
# Test the automated container scanning by deploying a test container
# The EventProcessor function should automatically trigger and scan it

set -e

RG="qualys-scanner-rg"
TEST_CONTAINER_NAME="test-automation-$(date +%s)"

echo "==========================================="
echo "  Testing Automated Container Scanning"
echo "==========================================="
echo ""

echo "This script will:"
echo "  1. Deploy a test container (nginx)"
echo "  2. Wait for Event Grid to trigger the scanner"
echo "  3. Monitor the Function App logs"
echo "  4. Verify the scan completed"
echo ""

read -p "Press Enter to continue or Ctrl+C to cancel..."

echo ""
echo "=== Deploying Test Container ==="
echo "Container name: $TEST_CONTAINER_NAME"
echo "Image: nginx:latest"
echo ""

az container create \
  --resource-group $RG \
  --name $TEST_CONTAINER_NAME \
  --image nginx:latest \
  --cpu 1 \
  --memory 1 \
  --restart-policy Always \
  --ports 80 \
  --output none

echo "✓ Container deployed"
echo ""

echo "=== Waiting for Event Grid to trigger scanner (30 seconds) ==="
sleep 30

echo ""
echo "=== Checking Function App Logs ==="
FUNCTION_APP=$(az functionapp list --resource-group $RG --query "[0].name" -o tsv)
APP_INSIGHTS=$(az monitor app-insights component list --resource-group $RG --query "[0].name" -o tsv)

echo "Function App: $FUNCTION_APP"
echo "App Insights: $APP_INSIGHTS"
echo ""

echo "Recent EventProcessor logs (last 5 minutes):"
az monitor app-insights query \
  --app "$APP_INSIGHTS" \
  --analytics-query "traces
    | where timestamp > ago(5m)
    | where operation_Name == 'EventProcessor'
    | project timestamp, message
    | order by timestamp desc
    | take 20" \
  --output table

echo ""
echo "=== Checking for QScanner Activity ==="
echo "Looking for qscanner containers..."

az container list \
  --resource-group $RG \
  --query "[?contains(name, 'qscanner')].{Name:name, State:instanceView.state, Started:containers[0].instanceView.currentState.startTime}" \
  --output table

echo ""
echo "=== Test Container Info ==="
az container show \
  --resource-group $RG \
  --name $TEST_CONTAINER_NAME \
  --query "{Name:name, State:instanceView.state, Image:containers[0].image}" \
  --output table

echo ""
echo "=== Diagnosis ==="
echo ""
echo "If you see qscanner containers above, the automation is working!"
echo "If not, check the Function App logs for errors:"
echo ""
echo "  az functionapp log tail --resource-group $RG --name $FUNCTION_APP"
echo ""
echo "Clean up test container:"
echo "  az container delete --resource-group $RG --name $TEST_CONTAINER_NAME --yes"
echo ""
