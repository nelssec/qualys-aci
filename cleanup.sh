#!/bin/bash
set -e

RG="${RESOURCE_GROUP:-qualys-scanner-rg}"

echo "Cleaning up Qualys Scanner"
echo "Resource Group: $RG"
echo ""

if az group show --name "$RG" &>/dev/null; then
  echo "Deleting resource group: $RG"
  read -p "Are you sure? (yes/no): " -r
  if [[ $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    az group delete --name "$RG" --yes --no-wait
    echo "Resource group deletion initiated"
  else
    echo "Cleanup cancelled"
    exit 0
  fi
else
  echo "Resource group $RG does not exist"
fi

echo ""
echo "Checking for orphaned role assignments..."
SUB_ID=$(az account show --query id -o tsv)
ORPHANED=$(az role assignment list \
  --role "Reader" \
  --scope "/subscriptions/$SUB_ID" \
  --query "[?principalType=='ServicePrincipal' && principalName==null].id" -o tsv 2>/dev/null || true)

if [ ! -z "$ORPHANED" ]; then
  echo "Cleaning up orphaned role assignments..."
  for assignment in $ORPHANED; do
    az role assignment delete --ids "$assignment" 2>/dev/null || true
  done
else
  echo "No orphaned role assignments found"
fi

echo ""
echo "Deleting Service Principal..."
SP_NAME="${SP_NAME:-qualys-acr-scanner}"
SP_ID=$(az ad sp list --display-name "$SP_NAME" --query "[0].appId" -o tsv 2>/dev/null || true)
if [ -n "$SP_ID" ]; then
  az ad sp delete --id "$SP_ID" 2>/dev/null && echo "Deleted: $SP_NAME" || echo "Could not delete SP"
else
  echo "No Service Principal found: $SP_NAME"
fi

echo ""
echo "Full cleanup complete"
echo "Note: Remember to delete the ACR connector/registry from Qualys console if no longer needed"
echo ""
