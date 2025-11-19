#!/bin/bash
# Clean up old Qualys scanner deployment
set -e

RG="${RESOURCE_GROUP:-qualys-scanner-rg}"

echo "========================================="
echo "Cleaning up Qualys Scanner Deployment"
echo "========================================="
echo "Resource Group: $RG"
echo ""

# Check if resource group exists
if az group show --name "$RG" &>/dev/null; then
  echo "Deleting resource group: $RG"
  echo "This will delete:"
  echo "  - Function App and App Service Plan"
  echo "  - Storage Account and scan data"
  echo "  - Key Vault and secrets"
  echo "  - Application Insights"
  echo "  - Event Grid system topic and subscriptions"
  echo ""

  read -p "Are you sure? (yes/no): " -r
  if [[ $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    # Delete resource group (this handles most cleanup)
    az group delete --name "$RG" --yes --no-wait

    echo "Resource group deletion initiated (running in background)"
    echo "Check status: az group show --name $RG"
  else
    echo "Cleanup cancelled"
    exit 0
  fi
else
  echo "Resource group $RG does not exist, nothing to clean up"
fi

# Clean up subscription-level role assignments for old function apps
echo ""
echo "Checking for orphaned subscription-level role assignments..."
CONTRIBUTOR_ROLE_ID="b24988ac-6180-42a0-ab88-20f7382dd24c"

# Find and delete role assignments for deleted function apps
ORPHANED_ASSIGNMENTS=$(az role assignment list \
  --role "$CONTRIBUTOR_ROLE_ID" \
  --scope "/subscriptions/$(az account show --query id -o tsv)" \
  --query "[?principalType=='ServicePrincipal' && !principalId].assignmentId" -o tsv 2>/dev/null || true)

if [ ! -z "$ORPHANED_ASSIGNMENTS" ]; then
  echo "Found orphaned role assignments, cleaning up..."
  for assignment in $ORPHANED_ASSIGNMENTS; do
    echo "  Deleting: $assignment"
    az role assignment delete --ids "$assignment" 2>/dev/null || true
  done
else
  echo "No orphaned role assignments found"
fi

# Clean up Event Grid system topics in the deleted resource group
echo ""
echo "Event Grid cleanup:"
TOPIC_NAME="qscan-aci-topic"
if az eventgrid system-topic show --name "$TOPIC_NAME" --resource-group "$RG" &>/dev/null 2>&1; then
  echo "  Deleting Event Grid system topic: $TOPIC_NAME"
  az eventgrid system-topic delete --name "$TOPIC_NAME" --resource-group "$RG" --yes 2>/dev/null || true
else
  echo "  Event Grid topic will be deleted with resource group"
fi

echo ""
echo "========================================="
echo "Cleanup Complete!"
echo "========================================="
echo ""
echo "Wait for resource group deletion to complete:"
echo "  az group show --name $RG"
echo ""
echo "When deletion is complete (returns 'ResourceGroupNotFound'), deploy fresh:"
echo "  ./deploy.sh"
echo "  OR follow manual deployment steps in README.md"
echo ""
