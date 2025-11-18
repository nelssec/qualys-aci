#!/bin/bash
# Debug script: Test automated container scanning
# Deploys test container and monitors scan execution

set -e

RG="qualys-scanner-rg"
TEST_CONTAINER_NAME="test-automation-$(date +%s)"
TEST_IMAGE="mcr.microsoft.com/azuredocs/aci-helloworld:latest"

echo "Testing Automated Container Scanning"
echo "Container: $TEST_CONTAINER_NAME"
echo "Image: $TEST_IMAGE"
echo ""

az container create \
  --resource-group $RG \
  --name $TEST_CONTAINER_NAME \
  --image $TEST_IMAGE \
  --cpu 1 \
  --memory 1 \
  --os-type Linux \
  --restart-policy Always \
  --ports 80 \
  --output none

echo "Container deployed"
echo "Waiting for Event Grid to trigger scanner (30 seconds)"
sleep 30
echo ""

FUNCTION_APP=$(az functionapp list --resource-group $RG --query "[0].name" -o tsv)
APP_INSIGHTS_ID=$(az monitor app-insights component list --resource-group $RG --query "[0].appId" -o tsv)

echo "Recent EventProcessor logs:"
az monitor app-insights query \
  --app "$APP_INSIGHTS_ID" \
  --analytics-query "traces
    | where timestamp > ago(5m)
    | where operation_Name == 'EventProcessor'
    | project timestamp, message
    | order by timestamp desc
    | take 20" \
  --output table

echo ""
echo "QScanner containers:"
az container list \
  --resource-group $RG \
  --query "[?contains(name, 'qscanner')].{Name:name, State:instanceView.state, Started:containers[0].instanceView.currentState.startTime}" \
  --output table

echo ""
echo "Test container:"
az container show \
  --resource-group $RG \
  --name $TEST_CONTAINER_NAME \
  --query "{Name:name, State:instanceView.state, Image:containers[0].image}" \
  --output table

echo ""
echo "Clean up: az container delete --resource-group $RG --name $TEST_CONTAINER_NAME --yes"
