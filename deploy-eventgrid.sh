#!/bin/bash
# Deploy Event Grid subscriptions after function code is deployed

set -e

RG="qualys-scanner-rg"

echo "=== Getting deployment outputs ==="
FUNCTION_APP=$(az deployment group show \
  --resource-group $RG \
  --name main \
  --query "properties.outputs.functionAppName.value" -o tsv)

EVENT_GRID_TOPIC=$(az deployment group show \
  --resource-group $RG \
  --name main \
  --query "properties.outputs.eventGridTopicName.value" -o tsv)

echo "Function App: $FUNCTION_APP"
echo "Event Grid Topic: $EVENT_GRID_TOPIC"

echo ""
echo "=== Verifying Event Grid system topic exists ==="
az eventgrid system-topic show \
  --resource-group $RG \
  --name "$EVENT_GRID_TOPIC" \
  --query "{Name:name, Source:source, TopicType:topicType, ProvisioningState:provisioningState}" \
  --output table

echo ""
echo "=== Deploying Event Grid subscriptions ==="
az deployment group create \
  --resource-group $RG \
  --name eventgrid-subscriptions \
  --template-file infrastructure/eventgrid.bicep \
  --parameters infrastructure/eventgrid.bicepparam \
  --parameters functionAppName="$FUNCTION_APP" \
  --parameters eventGridTopicName="$EVENT_GRID_TOPIC"

echo ""
echo "=== Verifying Event Grid subscriptions ==="
az eventgrid system-topic event-subscription list \
  --resource-group $RG \
  --system-topic-name "$EVENT_GRID_TOPIC" \
  --query "[].{Name:name, ProvisioningState:provisioningState, Endpoint:destination.endpointType}" \
  --output table

echo ""
echo "Event Grid subscriptions deployed successfully!"
echo "The EventProcessor function will now be triggered when containers are deployed."
