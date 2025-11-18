#!/bin/bash
# View scan results from Azure Storage

set -e

RG="${RESOURCE_GROUP:-qualys-scanner-rg}"

echo "Fetching scan results from Azure Storage..."
echo ""

STORAGE_ACCOUNT=$(az storage account list \
  --resource-group "$RG" \
  --query "[0].name" -o tsv)

if [ -z "$STORAGE_ACCOUNT" ]; then
  echo "ERROR: Storage account not found"
  exit 1
fi

echo "Storage Account: $STORAGE_ACCOUNT"
echo ""

# Get storage account key
STORAGE_KEY=$(az storage account keys list \
  --resource-group "$RG" \
  --account-name "$STORAGE_ACCOUNT" \
  --query "[0].value" -o tsv)

# List recent scan results from blob storage
echo "Recent scan results (blobs):"
az storage blob list \
  --account-name "$STORAGE_ACCOUNT" \
  --account-key "$STORAGE_KEY" \
  --container-name "scan-results" \
  --query "[].{Name:name, Created:properties.creationTime, Size:properties.contentLength}" \
  --output table 2>/dev/null || echo "No blob results found"

echo ""

# List scan results from table storage
echo "Recent scan results (table):"
az storage entity query \
  --account-name "$STORAGE_ACCOUNT" \
  --account-key "$STORAGE_KEY" \
  --table-name "scanresults" \
  --query "[].{Timestamp:Timestamp, Image:image, Status:status, Vulns:vulnerabilities}" \
  --output table 2>/dev/null || echo "No table results found"

echo ""
echo "To download a specific scan result:"
echo "az storage blob download --account-name $STORAGE_ACCOUNT --account-key <KEY> --container-name scan-results --name <blob-name> --file result.json"
