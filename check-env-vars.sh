#!/bin/bash
# Check if all required environment variables are configured

set -e

RG="qualys-scanner-rg"
FUNCTION_APP=$(az functionapp list --resource-group $RG --query "[0].name" -o tsv)

echo "=== Checking all function app settings ==="
az functionapp config appsettings list \
  --resource-group $RG \
  --name $FUNCTION_APP \
  --output table

echo ""
echo "=== Checking required environment variables ==="

REQUIRED_VARS=(
  "QUALYS_ACCESS_TOKEN"
  "QUALYS_POD"
  "AZURE_SUBSCRIPTION_ID"
  "RESOURCE_GROUP"
  "STORAGE_CONNECTION_STRING"
  "QSCANNER_IMAGE"
)

MISSING_VARS=()

for var in "${REQUIRED_VARS[@]}"; do
  VALUE=$(az functionapp config appsettings list \
    --resource-group $RG \
    --name $FUNCTION_APP \
    --query "[?name=='$var'].value" -o tsv 2>/dev/null)

  if [ -z "$VALUE" ]; then
    echo "❌ $var: NOT SET"
    MISSING_VARS+=("$var")
  else
    # Mask sensitive values
    if [[ "$var" == *"TOKEN"* ]] || [[ "$var" == *"CONNECTION_STRING"* ]]; then
      echo "✓ $var: ***configured***"
    else
      echo "✓ $var: $VALUE"
    fi
  fi
done

if [ ${#MISSING_VARS[@]} -gt 0 ]; then
  echo ""
  echo "ERROR: Missing required environment variables:"
  for var in "${MISSING_VARS[@]}"; do
    echo "  - $var"
  done
  exit 1
else
  echo ""
  echo "✓ All required environment variables are configured"
fi
