.PHONY: deploy deploy-hub deploy-spoke clean clean-all create-sp delete-sp check-prereqs help status logs test-scan

RESOURCE_GROUP ?= qualys-scanner-rg
LOCATION ?= eastus
SP_NAME ?= qualys-acr-scanner

define get_gateway_url
$(if $(filter US1,$(1)),https://gateway.qg1.apps.qualys.com,\
$(if $(filter US2,$(1)),https://gateway.qg2.apps.qualys.com,\
$(if $(filter US3,$(1)),https://gateway.qg3.apps.qualys.com,\
$(if $(filter EU1,$(1)),https://gateway.qg1.apps.qualys.eu,\
$(if $(filter EU2,$(1)),https://gateway.qg2.apps.qualys.eu,\
$(if $(filter CA1,$(1)),https://gateway.qg1.apps.qualys.ca,\
$(if $(filter AU1,$(1)),https://gateway.qg1.apps.qualys.com.au,$(1))))))))
endef

help: ## Show this help
	@echo "Qualys Container Scanner for ACI/ACA"
	@echo ""
	@echo "Usage:"
	@echo "  export QUALYS_ACCESS_TOKEN='your-token'"
	@echo "  make deploy QUALYS_POD=CA1"
	@echo ""
	@echo "Targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-20s %s\n", $$1, $$2}'
	@echo ""
	@echo "Environment variables:"
	@echo "  QUALYS_ACCESS_TOKEN  Required. Your Qualys Container Security API token"
	@echo "  QUALYS_POD           Required. POD name: US1, US2, US3, EU1, EU2, CA1, AU1"
	@echo "  RESOURCE_GROUP       Azure resource group name (default: qualys-scanner-rg)"
	@echo "  LOCATION             Azure region (default: eastus)"

check-prereqs: ## Verify prerequisites
	@echo "Checking prerequisites..."
	@command -v az >/dev/null 2>&1 || { echo "ERROR: Azure CLI (az) not found"; exit 1; }
	@command -v func >/dev/null 2>&1 || { echo "ERROR: Azure Functions Core Tools (func) not found"; exit 1; }
	@az account show >/dev/null 2>&1 || { echo "ERROR: Not logged in to Azure. Run: az login"; exit 1; }
	@echo "All prerequisites satisfied"

create-sp: check-prereqs ## Create ACR Service Principal
	@echo "Creating Service Principal: $(SP_NAME)"
	@SUBSCRIPTION_ID=$$(az account show --query id -o tsv) && \
	SP_OUTPUT=$$(az ad sp create-for-rbac --name "$(SP_NAME)" --role AcrPull --scopes "/subscriptions/$$SUBSCRIPTION_ID" -o json) && \
	echo "$$SP_OUTPUT" > .sp-credentials.json && \
	chmod 600 .sp-credentials.json && \
	echo "Service Principal created. Credentials saved to .sp-credentials.json"

delete-sp: ## Delete ACR Service Principal
	@echo "Deleting Service Principal: $(SP_NAME)"
	@az ad sp delete --id $$(az ad sp list --display-name "$(SP_NAME)" --query "[0].appId" -o tsv) 2>/dev/null || true
	@rm -f .sp-credentials.json
	@echo "Service Principal deleted"

deploy: check-prereqs ## Deploy the scanner (auto-creates SP if needed)
ifndef QUALYS_ACCESS_TOKEN
	$(error QUALYS_ACCESS_TOKEN is required. Set it with: export QUALYS_ACCESS_TOKEN='your-token')
endif
ifndef QUALYS_POD
	$(error QUALYS_POD is required. Usage: make deploy QUALYS_POD=CA1)
endif
	$(eval QUALYS_GATEWAY_URL := $(call get_gateway_url,$(QUALYS_POD)))
	@echo "Qualys Container Scanner for ACI/ACA"
	@echo "====================================="
	@echo "Subscription: $$(az account show --query name -o tsv)"
	@echo "Resource Group: $(RESOURCE_GROUP)"
	@echo "Location: $(LOCATION)"
	@echo "Qualys POD: $(QUALYS_POD)"
	@echo "Qualys Gateway: $(QUALYS_GATEWAY_URL)"
	@echo ""
	@if [ -z "$(ACR_APPLICATION_ID)" ] || [ -z "$(ACR_CLIENT_SECRET)" ]; then \
		if [ -f .sp-credentials.json ]; then \
			echo "Using existing Service Principal from .sp-credentials.json"; \
			ACR_APPLICATION_ID=$$(cat .sp-credentials.json | grep -o '"appId"[^,]*' | cut -d'"' -f4); \
			ACR_CLIENT_SECRET=$$(cat .sp-credentials.json | grep -o '"password"[^,]*' | cut -d'"' -f4); \
		else \
			echo "Creating Service Principal for ACR access..."; \
			SUBSCRIPTION_ID=$$(az account show --query id -o tsv); \
			SP_OUTPUT=$$(az ad sp create-for-rbac --name "$(SP_NAME)" --role AcrPull --scopes "/subscriptions/$$SUBSCRIPTION_ID" -o json); \
			echo "$$SP_OUTPUT" > .sp-credentials.json; \
			chmod 600 .sp-credentials.json; \
			ACR_APPLICATION_ID=$$(echo "$$SP_OUTPUT" | grep -o '"appId"[^,]*' | cut -d'"' -f4); \
			ACR_CLIENT_SECRET=$$(echo "$$SP_OUTPUT" | grep -o '"password"[^,]*' | cut -d'"' -f4); \
		fi; \
	else \
		ACR_APPLICATION_ID="$(ACR_APPLICATION_ID)"; \
		ACR_CLIENT_SECRET="$(ACR_CLIENT_SECRET)"; \
	fi && \
	FORCE_DEPLOY=1 \
	QUALYS_API_TOKEN="$(QUALYS_ACCESS_TOKEN)" \
	QUALYS_GATEWAY_URL="$(QUALYS_GATEWAY_URL)" \
	RESOURCE_GROUP="$(RESOURCE_GROUP)" \
	LOCATION="$(LOCATION)" \
	ACR_APPLICATION_ID="$$ACR_APPLICATION_ID" \
	ACR_CLIENT_SECRET="$$ACR_CLIENT_SECRET" \
	./deploy.sh

deploy-hub: check-prereqs ## Deploy hub only (for multi-subscription setup)
ifndef QUALYS_ACCESS_TOKEN
	$(error QUALYS_ACCESS_TOKEN is required)
endif
ifndef QUALYS_POD
	$(error QUALYS_POD is required)
endif
ifndef HUB_SUBSCRIPTION_ID
	$(error HUB_SUBSCRIPTION_ID is required. Usage: make deploy-hub QUALYS_POD=CA1 HUB_SUBSCRIPTION_ID=<id>)
endif
	$(eval QUALYS_GATEWAY_URL := $(call get_gateway_url,$(QUALYS_POD)))
	@if [ -z "$(ACR_APPLICATION_ID)" ] || [ -z "$(ACR_CLIENT_SECRET)" ]; then \
		if [ -f .sp-credentials.json ]; then \
			ACR_APPLICATION_ID=$$(cat .sp-credentials.json | grep -o '"appId"[^,]*' | cut -d'"' -f4); \
			ACR_CLIENT_SECRET=$$(cat .sp-credentials.json | grep -o '"password"[^,]*' | cut -d'"' -f4); \
		else \
			$(MAKE) create-sp; \
			ACR_APPLICATION_ID=$$(cat .sp-credentials.json | grep -o '"appId"[^,]*' | cut -d'"' -f4); \
			ACR_CLIENT_SECRET=$$(cat .sp-credentials.json | grep -o '"password"[^,]*' | cut -d'"' -f4); \
		fi; \
	else \
		ACR_APPLICATION_ID="$(ACR_APPLICATION_ID)"; \
		ACR_CLIENT_SECRET="$(ACR_CLIENT_SECRET)"; \
	fi && \
	FORCE_DEPLOY=1 \
	QUALYS_API_TOKEN="$(QUALYS_ACCESS_TOKEN)" \
	QUALYS_GATEWAY_URL="$(QUALYS_GATEWAY_URL)" \
	RESOURCE_GROUP="$(RESOURCE_GROUP)" \
	LOCATION="$(LOCATION)" \
	HUB_SUBSCRIPTION_ID="$(HUB_SUBSCRIPTION_ID)" \
	ACR_APPLICATION_ID="$$ACR_APPLICATION_ID" \
	ACR_CLIENT_SECRET="$$ACR_CLIENT_SECRET" \
	./deploy-hub.sh

deploy-spoke: ## Deploy spoke subscription (requires hub deployed first)
ifndef SPOKE_SUBSCRIPTION_ID
	$(error SPOKE_SUBSCRIPTION_ID required. Usage: make deploy-spoke SPOKE_SUBSCRIPTION_ID=<id>)
endif
	@./deploy-spoke.sh

clean: ## Clean local files only
	@echo "Cleaning local files..."
	@rm -f .sp-credentials.json .deployment-outputs.json
	@echo "Local files cleaned"

clean-all: clean ## Full teardown: Azure resources + Service Principal
	@./cleanup.sh

status: ## Show deployment status
	@echo "Deployment Status"
	@echo "================="
	@echo "Resource Group: $(RESOURCE_GROUP)"
	@echo ""
	@az group show --name "$(RESOURCE_GROUP)" --query '{state:properties.provisioningState, location:location}' -o table 2>/dev/null || echo "Resource group not found"
	@echo ""
	@echo "Function App:"
	@az functionapp list --resource-group "$(RESOURCE_GROUP)" --query "[].{name:name, state:state, runtime:siteConfig.linuxFxVersion}" -o table 2>/dev/null || echo "No function apps found"

logs: ## Stream function app logs
	@FUNCTION_APP=$$(az functionapp list --resource-group "$(RESOURCE_GROUP)" --query "[0].name" -o tsv 2>/dev/null) && \
	if [ -n "$$FUNCTION_APP" ]; then \
		echo "Streaming logs for $$FUNCTION_APP (Ctrl+C to stop)..."; \
		func azure functionapp logstream "$$FUNCTION_APP"; \
	else \
		echo "No function app found in $(RESOURCE_GROUP)"; \
	fi

test-scan: ## Deploy a test container to trigger scan
ifndef TEST_IMAGE
	$(error TEST_IMAGE required. Usage: make test-scan TEST_IMAGE=myacr.azurecr.io/myimage:tag)
endif
	@echo "Deploying test container to trigger scan..."
	@az container create \
		--resource-group "$(RESOURCE_GROUP)" \
		--name "test-scan-$$(date +%s)" \
		--image "$(TEST_IMAGE)" \
		--os-type Linux \
		--cpu 1 \
		--memory 1 \
		--restart-policy Never
	@echo ""
	@echo "Container deployed. Check function logs with: make logs"
