#!/bin/bash
# Test if qscanner image can run in ACI

set -e

RG="qualys-scanner-rg"
ACR_NAME=$(az acr list --resource-group $RG --query "[0].name" -o tsv)
ACR_SERVER=$(az acr list --resource-group $RG --query "[0].loginServer" -o tsv)
QUALYS_TOKEN=$(az keyvault secret show --vault-name $(az keyvault list --resource-group $RG --query "[0].name" -o tsv) --name QualysAccessToken --query "value" -o tsv)

echo "=========================================="
echo "  Testing QScanner Image in ACI"
echo "=========================================="
echo ""

echo "=== 1. Checking if qscanner image exists in ACR ==="
echo "ACR: $ACR_SERVER"
echo ""

az acr repository list --name $ACR_NAME --output table

if ! az acr repository show --name $ACR_NAME --repository qualys/qscanner >/dev/null 2>&1; then
  echo ""
  echo "❌ qscanner image not found in ACR!"
  echo ""
  echo "Importing qscanner image from Docker Hub..."
  az acr import \
    --name $ACR_NAME \
    --source docker.io/qualys/qscanner:latest \
    --image qualys/qscanner:latest

  echo "✓ Image imported successfully"
fi

echo ""
echo "=== 2. Creating test qscanner container ==="
TEST_IMAGE="mcr.microsoft.com/azuredocs/aci-helloworld:latest"
CONTAINER_NAME="qscanner-manual-test-$(date +%s)"

echo "Container name: $CONTAINER_NAME"
echo "Scanning image: $TEST_IMAGE"
echo ""

# Enable ACR admin for pulling
echo "Enabling ACR admin credentials..."
az acr update --name $ACR_NAME --admin-enabled true --output none

ACR_USERNAME=$(az acr credential show --name $ACR_NAME --query "username" -o tsv)
ACR_PASSWORD=$(az acr credential show --name $ACR_NAME --query "passwords[0].value" -o tsv)

# Create qscanner container with the same settings as the function would use
az container create \
  --resource-group $RG \
  --name $CONTAINER_NAME \
  --image "${ACR_SERVER}/qualys/qscanner:latest" \
  --registry-login-server $ACR_SERVER \
  --registry-username $ACR_USERNAME \
  --registry-password $ACR_PASSWORD \
  --cpu 2 \
  --memory 4 \
  --restart-policy Never \
  --os-type Linux \
  --environment-variables \
    QUALYS_ACCESS_TOKEN="$QUALYS_TOKEN" \
  --command-line "image $TEST_IMAGE --pod US2 --scan-types os,sca,secret --format json --skip-verify-tls" \
  --output none

echo "✓ Container created"
echo ""
echo "Waiting 30 seconds for container to start..."
sleep 30

echo ""
echo "=== 3. Checking container status ==="
az container show \
  --resource-group $RG \
  --name $CONTAINER_NAME \
  --query "{Name:name, State:instanceView.state, ExitCode:containers[0].instanceView.currentState.exitCode, StartTime:containers[0].instanceView.currentState.startTime}" \
  --output table

echo ""
echo "=== 4. Container events ==="
az container show \
  --resource-group $RG \
  --name $CONTAINER_NAME \
  --query "containers[0].instanceView.events[].{Time:firstTimestamp, Type:type, Name:name, Message:message}" \
  --output table

echo ""
echo "=== 5. Container logs ==="
az container logs \
  --resource-group $RG \
  --name $CONTAINER_NAME 2>&1 || echo "No logs available"

echo ""
echo "=== 6. Diagnosis ==="
STATE=$(az container show --resource-group $RG --name $CONTAINER_NAME --query "instanceView.state" -o tsv)
EXIT_CODE=$(az container show --resource-group $RG --name $CONTAINER_NAME --query "containers[0].instanceView.currentState.exitCode" -o tsv)

if [ "$STATE" = "Succeeded" ] && [ "$EXIT_CODE" = "0" ]; then
  echo "✓ SUCCESS! QScanner ran successfully in ACI"
elif [ "$STATE" = "Failed" ]; then
  echo "❌ FAILED! QScanner container failed"
  echo "Check the events and logs above for details"
elif [ "$STATE" = "Running" ]; then
  echo "⏳ Container is still running..."
  echo "Run: az container logs --resource-group $RG --name $CONTAINER_NAME"
else
  echo "State: $STATE, Exit Code: $EXIT_CODE"
fi

echo ""
echo "Clean up: az container delete --resource-group $RG --name $CONTAINER_NAME --yes"
