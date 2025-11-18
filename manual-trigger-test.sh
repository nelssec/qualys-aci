#!/bin/bash
# Manually trigger the EventProcessor function with a test Event Grid event

set -e

RG="qualys-scanner-rg"
FUNCTION_APP=$(az functionapp list --resource-group $RG --query "[0].name" -o tsv)
SUB_ID=$(az account show --query id -o tsv)

echo "=== Getting function key for manual trigger ==="
FUNCTION_KEY=$(az functionapp function keys list \
  --resource-group $RG \
  --name $FUNCTION_APP \
  --function-name EventProcessor \
  --query "default" -o tsv 2>/dev/null || echo "")

if [ -z "$FUNCTION_KEY" ]; then
  echo "Could not get function key, trying to get master host key..."
  FUNCTION_KEY=$(az functionapp keys list \
    --resource-group $RG \
    --name $FUNCTION_APP \
    --query "functionKeys.default" -o tsv 2>/dev/null || echo "")
fi

FUNCTION_URL="https://${FUNCTION_APP}.azurewebsites.net/runtime/webhooks/eventgrid?functionName=EventProcessor&code=${FUNCTION_KEY}"

echo "Function URL (without key): https://${FUNCTION_APP}.azurewebsites.net/runtime/webhooks/eventgrid?functionName=EventProcessor"
echo ""

# Create a test Event Grid event payload
cat > /tmp/test-event.json <<EOF
[{
  "id": "test-$(date +%s)",
  "eventType": "Microsoft.Resources.ResourceWriteSuccess",
  "subject": "/subscriptions/${SUB_ID}/resourceGroups/${RG}/providers/Microsoft.ContainerInstance/containerGroups/test-manual",
  "eventTime": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "data": {
    "subscriptionId": "${SUB_ID}",
    "resourceGroupName": "${RG}",
    "resourceProvider": "Microsoft.ContainerInstance",
    "resourceUri": "/subscriptions/${SUB_ID}/resourceGroups/${RG}/providers/Microsoft.ContainerInstance/containerGroups/test-manual",
    "operationName": "Microsoft.ContainerInstance/containerGroups/write",
    "status": "Succeeded",
    "authorization": {
      "scope": "/subscriptions/${SUB_ID}/resourceGroups/${RG}/providers/Microsoft.ContainerInstance/containerGroups/test-manual",
      "action": "Microsoft.ContainerInstance/containerGroups/write",
      "evidence": {
        "role": "Subscription Admin"
      }
    },
    "claims": {},
    "httpRequest": {
      "clientRequestId": "test-client-request-id",
      "clientIpAddress": "127.0.0.1",
      "method": "PUT",
      "url": "https://management.azure.com/subscriptions/${SUB_ID}/resourceGroups/${RG}/providers/Microsoft.ContainerInstance/containerGroups/test-manual?api-version=2021-09-01"
    },
    "properties": {
      "containers": [
        {
          "name": "test-container",
          "properties": {
            "image": "mcr.microsoft.com/azuredocs/aci-helloworld:latest",
            "ports": [],
            "environmentVariables": [],
            "resources": {
              "requests": {
                "cpu": 1.0,
                "memoryInGB": 1.0
              }
            }
          }
        }
      ],
      "osType": "Linux",
      "restartPolicy": "Never"
    }
  },
  "dataVersion": "2.0",
  "metadataVersion": "1",
  "topic": "/subscriptions/${SUB_ID}/resourceGroups/${RG}"
}]
EOF

echo "=== Test Event Grid payload ==="
cat /tmp/test-event.json | jq .
echo ""

echo "=== Sending test event to EventProcessor function ==="
RESPONSE=$(curl -X POST "$FUNCTION_URL" \
  -H "Content-Type: application/json" \
  -H "aeg-event-type: Notification" \
  -d @/tmp/test-event.json \
  -w "\nHTTP_STATUS:%{http_code}" \
  -s)

HTTP_STATUS=$(echo "$RESPONSE" | grep "HTTP_STATUS" | cut -d':' -f2)
BODY=$(echo "$RESPONSE" | grep -v "HTTP_STATUS")

echo "HTTP Status: $HTTP_STATUS"
echo "Response: $BODY"
echo ""

if [ "$HTTP_STATUS" = "200" ] || [ "$HTTP_STATUS" = "202" ]; then
  echo "SUCCESS! Function accepted the event."
  echo ""
  echo "Waiting 30 seconds for qscanner container to be created..."
  sleep 30

  echo ""
  echo "=== Checking for qscanner container ==="
  az container list \
    --resource-group $RG \
    --query "[?starts_with(name, 'qscanner-')].{Name:name, State:instanceView.state, Image:containers[0].image}" \
    --output table

  QSCANNER=$(az container list --resource-group $RG --query "[?starts_with(name, 'qscanner-')].name | [0]" -o tsv)
  if [ -n "$QSCANNER" ]; then
    echo ""
    echo "=== QScanner logs ==="
    az container logs --resource-group $RG --name "$QSCANNER"
  fi
else
  echo "FAILED! Function returned error status."
  echo "Check function app logs for details:"
  echo "az webapp log tail --resource-group $RG --name $FUNCTION_APP"
fi

rm -f /tmp/test-event.json
