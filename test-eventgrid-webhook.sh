#!/bin/bash
# Check Event Grid webhook endpoint health and delivery status

set -e

RG="qualys-scanner-rg"
EVENT_GRID_TOPIC=$(az eventgrid system-topic list --resource-group $RG --query "[0].name" -o tsv)

echo "=== Checking Event Grid subscription health ==="
az eventgrid system-topic event-subscription show \
  --resource-group $RG \
  --system-topic-name "$EVENT_GRID_TOPIC" \
  --name aci-container-deployments \
  --output json | jq '{
    name: .name,
    provisioningState: .provisioningState,
    endpoint: .destination.resourceId,
    endpointType: .destination.endpointType,
    deliveryWithResourceIdentity: .deliveryWithResourceIdentity,
    eventDeliverySchema: .eventDeliverySchema,
    filter: .filter
  }'

echo ""
echo "=== Checking for dead letter events ==="
# Check if there's a dead letter destination configured
DEAD_LETTER=$(az eventgrid system-topic event-subscription show \
  --resource-group $RG \
  --system-topic-name "$EVENT_GRID_TOPIC" \
  --name aci-container-deployments \
  --query "deadLetterDestination" -o json)

if [ "$DEAD_LETTER" != "null" ]; then
  echo "Dead letter destination configured:"
  echo "$DEAD_LETTER"
else
  echo "No dead letter destination configured (events that fail delivery are dropped)"
fi

echo ""
echo "=== Deploying a new test container and monitoring Event Grid ==="
TEST_NAME="eventgrid-test-$(date +%s)"
echo "Creating container: $TEST_NAME"

# Start monitoring in background
echo "Monitoring Event Grid metrics..."
(
  sleep 5
  echo "Checking Event Grid metrics after container creation..."
  TOPIC_ID=$(az eventgrid system-topic show \
    --resource-group $RG \
    --name "$EVENT_GRID_TOPIC" \
    --query "id" -o tsv)

  # Try to get metrics
  az monitor metrics list \
    --resource "$TOPIC_ID" \
    --metric "PublishSuccessCount" \
    --aggregation Total \
    --interval PT1M \
    --output table 2>&1 || echo "Could not retrieve metrics"
) &

# Create the container
az container create \
  --resource-group $RG \
  --name "$TEST_NAME" \
  --image mcr.microsoft.com/azuredocs/aci-helloworld:latest \
  --os-type Linux \
  --cpu 1 \
  --memory 1 \
  --restart-policy Never \
  --no-wait

echo "Container creation initiated"
echo "Waiting 45 seconds for Event Grid to process..."
sleep 45

echo ""
echo "=== Checking container status ==="
az container show \
  --resource-group $RG \
  --name "$TEST_NAME" \
  --query "{Name:name, State:instanceView.state, ProvisioningState:provisioningState}" \
  --output table 2>/dev/null || echo "Container not found yet"

echo ""
echo "=== Checking for qscanner containers ==="
QSCANNER_COUNT=$(az container list \
  --resource-group $RG \
  --query "[?starts_with(name, 'qscanner-')] | length(@)")

echo "Found $QSCANNER_COUNT qscanner container(s)"

if [ "$QSCANNER_COUNT" -gt 0 ]; then
  az container list \
    --resource-group $RG \
    --query "[?starts_with(name, 'qscanner-')].{Name:name, State:instanceView.state}" \
    --output table
else
  echo ""
  echo "No qscanner containers created - Event Grid or function may not be working"
  echo ""
  echo "Possible issues:"
  echo "1. Event Grid subscription not receiving events"
  echo "2. Event Grid endpoint validation failed"
  echo "3. Function is receiving events but failing silently"
  echo "4. Function code has import errors or missing dependencies"
  echo ""
  echo "Next steps:"
  echo "- Run ./check-function-logs.sh to see function execution logs"
  echo "- Check Azure Portal > Event Grid System Topic > Metrics for delivery attempts"
  echo "- Check Azure Portal > Function App > Monitor for invocation history"
fi

# Cleanup
wait
