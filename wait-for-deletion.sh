#!/bin/bash
# Wait for Azure resource group deletion to complete
# Usage: ./wait-for-deletion.sh [resource-group-name]

set -e

RG="${1:-qualys-scanner-rg}"

echo "Checking deletion status for resource group: $RG"

# Check current state
STATE=$(az group show --name "$RG" --query 'properties.provisioningState' -o tsv 2>/dev/null || echo "NotFound")

if [ "$STATE" == "NotFound" ]; then
  echo "✓ Resource group does not exist - ready for fresh deployment"
  exit 0
fi

if [ "$STATE" == "Deleting" ]; then
  echo "Resource group is being deleted. Waiting for completion..."
  echo "Started at: $(date)"

  WAIT_TIME=0
  while [ "$(az group show --name $RG --query 'properties.provisioningState' -o tsv 2>/dev/null || echo 'NotFound')" == "Deleting" ]; do
    echo "  Still deleting... (elapsed: ${WAIT_TIME}s)"
    sleep 10
    WAIT_TIME=$((WAIT_TIME + 10))

    if [ $WAIT_TIME -gt 600 ]; then
      echo "WARNING: Deletion taking longer than 10 minutes. This is unusual."
      echo "You may want to check Azure Portal or contact support."
    fi
  done

  echo "✓ Deletion complete! (total time: ${WAIT_TIME}s)"
  echo "Ended at: $(date)"
  exit 0
fi

echo "✓ Resource group exists in state: $STATE"
echo "Not currently deleting. You can:"
echo "  1. Run ./cleanup.sh to delete it"
echo "  2. Run deployment (may cause conflicts if resources exist)"
exit 0
