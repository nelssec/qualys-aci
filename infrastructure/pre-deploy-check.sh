#!/bin/bash

set -e

echo "=== Pre-Deployment Validation ==="
echo ""

ERRORS=0
WARNINGS=0

check_az_cli() {
    echo "[1/7] Checking Azure CLI version..."
    if ! command -v az &> /dev/null; then
        echo "ERROR: Azure CLI not found. Install from https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
        ((ERRORS++))
        return 1
    fi

    AZ_VERSION=$(az version --query '"azure-cli"' -o tsv)
    REQUIRED_VERSION="2.50.0"

    if ! printf '%s\n' "$REQUIRED_VERSION" "$AZ_VERSION" | sort -V -C; then
        echo "WARNING: Azure CLI version $AZ_VERSION is older than recommended $REQUIRED_VERSION"
        ((WARNINGS++))
    else
        echo "OK: Azure CLI version $AZ_VERSION"
    fi
}

check_logged_in() {
    echo "[2/7] Checking Azure login status..."
    if ! az account show &> /dev/null; then
        echo "ERROR: Not logged into Azure. Run 'az login'"
        ((ERRORS++))
        return 1
    fi

    SUBSCRIPTION_ID=$(az account show --query id -o tsv)
    SUBSCRIPTION_NAME=$(az account show --query name -o tsv)
    echo "OK: Logged in to subscription '$SUBSCRIPTION_NAME' ($SUBSCRIPTION_ID)"
}

check_permissions() {
    echo "[3/7] Checking subscription permissions..."
    USER_ID=$(az account show --query user.name -o tsv)
    SUBSCRIPTION_ID=$(az account show --query id -o tsv)

    CONTRIBUTOR=$(az role assignment list \
        --assignee "$USER_ID" \
        --scope "/subscriptions/$SUBSCRIPTION_ID" \
        --query "[?roleDefinitionName=='Contributor' || roleDefinitionName=='Owner'].roleDefinitionName" \
        -o tsv | head -n 1)

    if [ -z "$CONTRIBUTOR" ]; then
        echo "ERROR: User $USER_ID does not have Contributor or Owner role on subscription"
        echo "       Request access or use a different subscription"
        ((ERRORS++))
    else
        echo "OK: User has $CONTRIBUTOR role on subscription"
    fi
}

check_resource_providers() {
    echo "[4/7] Checking resource provider registration..."
    PROVIDERS=(
        "Microsoft.ContainerInstance"
        "Microsoft.App"
        "Microsoft.EventGrid"
        "Microsoft.Storage"
        "Microsoft.KeyVault"
        "Microsoft.Web"
    )

    UNREGISTERED=()
    for PROVIDER in "${PROVIDERS[@]}"; do
        STATE=$(az provider show --namespace "$PROVIDER" --query registrationState -o tsv 2>/dev/null || echo "NotFound")
        if [ "$STATE" != "Registered" ]; then
            UNREGISTERED+=("$PROVIDER")
        fi
    done

    if [ ${#UNREGISTERED[@]} -gt 0 ]; then
        echo "WARNING: The following providers are not registered:"
        for PROVIDER in "${UNREGISTERED[@]}"; do
            echo "         - $PROVIDER"
        done
        echo "         Run: az provider register --namespace <provider-name>"
        ((WARNINGS++))
    else
        echo "OK: All required resource providers are registered"
    fi
}

check_y1_quota() {
    echo "[5/7] Checking Y1 VM quota (for Consumption plan)..."
    LOCATION="${1:-eastus}"

    QUOTA=$(az vm list-usage --location "$LOCATION" \
        --query "[?name.value=='Y1'].{Current:currentValue,Limit:limit}" -o json 2>/dev/null)

    if [ -z "$QUOTA" ] || [ "$QUOTA" == "[]" ]; then
        echo "WARNING: Cannot determine Y1 quota for $LOCATION"
        echo "         If using Y1 (Consumption) plan, verify quota manually:"
        echo "         az vm list-usage --location $LOCATION --query \"[?name.value=='Y1']\""
        ((WARNINGS++))
    else
        LIMIT=$(echo "$QUOTA" | jq -r '.[0].Limit // 0')
        CURRENT=$(echo "$QUOTA" | jq -r '.[0].Current // 0')

        if [ "$LIMIT" -eq 0 ]; then
            echo "WARNING: Y1 VM quota is 0 in $LOCATION"
            echo "         Request quota increase or use a different SKU (EP1, P1v3)"
            echo "         Azure Portal > Subscriptions > Usage + quotas > Search 'Y1 VMs'"
            ((WARNINGS++))
        else
            AVAILABLE=$((LIMIT - CURRENT))
            echo "OK: Y1 quota: $CURRENT/$LIMIT used ($AVAILABLE available)"
        fi
    fi
}

check_func_core_tools() {
    echo "[6/7] Checking Azure Functions Core Tools..."
    if ! command -v func &> /dev/null; then
        echo "WARNING: Azure Functions Core Tools not found"
        echo "         Required for deploying function code"
        echo "         Install from https://docs.microsoft.com/en-us/azure/azure-functions/functions-run-local"
        ((WARNINGS++))
    else
        FUNC_VERSION=$(func --version)
        echo "OK: Azure Functions Core Tools version $FUNC_VERSION"
    fi
}

check_bicep_params() {
    echo "[7/7] Checking bicep parameter file..."
    PARAM_FILE="./main.bicepparam"

    if [ ! -f "$PARAM_FILE" ]; then
        echo "ERROR: Parameter file $PARAM_FILE not found"
        ((ERRORS++))
        return 1
    fi

    QUALYS_POD=$(grep "param qualysPod" "$PARAM_FILE" | grep -oP "= '\K[^']+")
    if [ -z "$QUALYS_POD" ]; then
        echo "WARNING: qualysPod not configured in $PARAM_FILE"
        ((WARNINGS++))
    else
        echo "OK: qualysPod configured: $QUALYS_POD"
    fi

    LOCATION=$(grep "param location" "$PARAM_FILE" | grep -oP "= '\K[^']+")
    if [ -z "$LOCATION" ]; then
        echo "WARNING: location not configured in $PARAM_FILE"
        ((WARNINGS++))
    else
        echo "OK: location configured: $LOCATION"
    fi
}

echo ""
check_az_cli
check_logged_in
check_permissions
check_resource_providers
check_y1_quota "${1:-eastus}"
check_func_core_tools
check_bicep_params

echo ""
echo "=== Validation Summary ==="
echo "Errors: $ERRORS"
echo "Warnings: $WARNINGS"
echo ""

if [ $ERRORS -gt 0 ]; then
    echo "FAILED: Fix errors before deploying"
    exit 1
elif [ $WARNINGS -gt 0 ]; then
    echo "PASSED: Review warnings before deploying"
    exit 0
else
    echo "PASSED: Ready to deploy"
    exit 0
fi
