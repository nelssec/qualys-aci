#!/bin/bash
# Verify complete deployment status

set -e

RG="${RESOURCE_GROUP:-qualys-scanner-rg}"

echo "Verifying Qualys Scanner Deployment"
echo "===================================="
echo ""

ERRORS=0

# 1. Check Function App
echo "[1/6] Function App"
FUNCTION_APP=$(az functionapp list --resource-group "$RG" --query "[0].name" -o tsv 2>/dev/null || echo "")
if [ -z "$FUNCTION_APP" ]; then
  echo "   ERROR: No function app found"
  ERRORS=$((ERRORS+1))
else
  STATE=$(az functionapp show --resource-group "$RG" --name "$FUNCTION_APP" --query "state" -o tsv)
  echo "   Name: $FUNCTION_APP"
  echo "   State: $STATE"
  if [ "$STATE" != "Running" ]; then
    echo "   WARNING: Function app not running"
    ERRORS=$((ERRORS+1))
  fi
fi
echo ""

# 2. Check EventProcessor function
echo "[2/6] EventProcessor Function"
if [ -n "$FUNCTION_APP" ]; then
  if az functionapp function show \
    --resource-group "$RG" \
    --name "$FUNCTION_APP" \
    --function-name "EventProcessor" \
    --query "name" -o tsv >/dev/null 2>&1; then
    echo "   Status: Deployed"
  else
    echo "   ERROR: EventProcessor function not found"
    echo "   Run: ./update.sh"
    ERRORS=$((ERRORS+1))
  fi
else
  echo "   SKIPPED: No function app"
fi
echo ""

# 3. Check Event Grid System Topic
echo "[3/6] Event Grid System Topic"
TOPIC_NAME=$(az eventgrid system-topic list \
  --resource-group "$RG" \
  --query "[0].name" -o tsv 2>/dev/null || echo "")
if [ -z "$TOPIC_NAME" ]; then
  echo "   ERROR: No Event Grid system topic found"
  echo "   This is created automatically by Azure for the resource group"
  echo "   Run: ./resume-deployment.sh"
  ERRORS=$((ERRORS+1))
else
  TOPIC_STATE=$(az eventgrid system-topic show \
    --resource-group "$RG" \
    --name "$TOPIC_NAME" \
    --query "provisioningState" -o tsv)
  echo "   Name: $TOPIC_NAME"
  echo "   State: $TOPIC_STATE"
  if [ "$TOPIC_STATE" != "Succeeded" ]; then
    echo "   WARNING: Topic not in Succeeded state"
    ERRORS=$((ERRORS+1))
  fi
fi
echo ""

# 4. Check Event Grid Subscriptions
echo "[4/6] Event Grid Subscriptions"
if [ -n "$TOPIC_NAME" ]; then
  SUBS=$(az eventgrid system-topic event-subscription list \
    --resource-group "$RG" \
    --system-topic-name "$TOPIC_NAME" \
    --query "length([])" -o tsv 2>/dev/null || echo "0")

  if [ "$SUBS" = "0" ]; then
    echo "   ERROR: No event subscriptions found"
    echo "   Run: ./resume-deployment.sh"
    ERRORS=$((ERRORS+1))
  else
    echo "   Count: $SUBS"
    az eventgrid system-topic event-subscription list \
      --resource-group "$RG" \
      --system-topic-name "$TOPIC_NAME" \
      --query "[].{Name:name, State:provisioningState}" \
      -o table

    # Check if subscriptions are succeeded
    FAILED=$(az eventgrid system-topic event-subscription list \
      --resource-group "$RG" \
      --system-topic-name "$TOPIC_NAME" \
      --query "[?provisioningState!='Succeeded'].name" -o tsv)

    if [ -n "$FAILED" ]; then
      echo "   WARNING: Some subscriptions not in Succeeded state:"
      echo "   $FAILED"
      ERRORS=$((ERRORS+1))
    fi
  fi
else
  echo "   SKIPPED: No system topic"
fi
echo ""

# 5. Check ACR for qscanner image
echo "[5/6] ACR QScanner Image"
ACR_NAME=$(az acr list --resource-group "$RG" --query "[0].name" -o tsv 2>/dev/null || echo "")
if [ -z "$ACR_NAME" ]; then
  echo "   ERROR: No ACR found"
  ERRORS=$((ERRORS+1))
else
  if az acr repository show \
    --name "$ACR_NAME" \
    --repository "qualys/qscanner" \
    --query "name" -o tsv >/dev/null 2>&1; then
    echo "   Status: qscanner image present in $ACR_NAME"
  else
    echo "   WARNING: qscanner image not in ACR"
    echo "   Run: az acr import --name $ACR_NAME --source docker.io/qualys/qscanner:latest --image qualys/qscanner:latest"
    ERRORS=$((ERRORS+1))
  fi
fi
echo ""

# 6. Check Key Vault token
echo "[6/6] Qualys Token"
KV_NAME=$(az keyvault list --resource-group "$RG" --query "[0].name" -o tsv 2>/dev/null || echo "")
if [ -z "$KV_NAME" ]; then
  echo "   ERROR: No Key Vault found"
  ERRORS=$((ERRORS+1))
else
  if az keyvault secret show \
    --vault-name "$KV_NAME" \
    --name "QualysAccessToken" \
    --query "value" -o tsv >/dev/null 2>&1; then
    TOKEN_LEN=$(az keyvault secret show \
      --vault-name "$KV_NAME" \
      --name "QualysAccessToken" \
      --query "value" -o tsv | wc -c)
    echo "   Status: Token exists (length: $TOKEN_LEN chars)"
    if [ "$TOKEN_LEN" -lt 100 ]; then
      echo "   WARNING: Token seems short, might be invalid"
    fi
  else
    echo "   ERROR: Cannot read Qualys token"
    echo "   Check Key Vault permissions"
    ERRORS=$((ERRORS+1))
  fi
fi
echo ""

echo "===================================="
if [ "$ERRORS" -eq 0 ]; then
  echo "Status: All checks passed"
  echo ""
  echo "Next steps:"
  echo "  - Test: ./test-automation.sh"
  echo "  - Check logs: ./view-logs.sh"
  exit 0
else
  echo "Status: $ERRORS issue(s) found"
  echo ""
  echo "Fix deployment:"
  echo "  - Event Grid: ./resume-deployment.sh"
  echo "  - Function: ./update.sh"
  echo "  - QScanner image: Import to ACR"
  exit 1
fi
