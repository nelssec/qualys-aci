#!/bin/bash

# Deploy qscanner on an Azure VM
# This script creates a VM and installs qscanner

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${YELLOW}ℹ $1${NC}"
}

usage() {
    cat << EOF
Usage: $0 -r <resource-group> -l <location> [OPTIONS]

Deploy qscanner on an Azure VM for container image scanning

Required:
    -r, --resource-group    Resource group name
    -l, --location          Azure region

Optional:
    -n, --vm-name           VM name (default: qscanner-vm)
    -s, --vm-size           VM size (default: Standard_D2s_v3)
    -u, --qualys-user       Qualys username
    -p, --qualys-pass       Qualys password
    -v, --vnet              VNet name for VM integration
    -h, --help              Show this help

Example:
    $0 -r qualys-rg -l eastus -u qualys_user -p qualys_pass
EOF
    exit 1
}

# Parse arguments
RESOURCE_GROUP=""
LOCATION=""
VM_NAME="qscanner-vm"
VM_SIZE="Standard_D2s_v3"
QUALYS_USER="${QUALYS_USERNAME:-}"
QUALYS_PASS="${QUALYS_PASSWORD:-}"
VNET_NAME=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -r|--resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
        -l|--location) LOCATION="$2"; shift 2 ;;
        -n|--vm-name) VM_NAME="$2"; shift 2 ;;
        -s|--vm-size) VM_SIZE="$2"; shift 2 ;;
        -u|--qualys-user) QUALYS_USER="$2"; shift 2 ;;
        -p|--qualys-pass) QUALYS_PASS="$2"; shift 2 ;;
        -v|--vnet) VNET_NAME="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) print_error "Unknown option: $1"; usage ;;
    esac
done

if [ -z "$RESOURCE_GROUP" ] || [ -z "$LOCATION" ]; then
    print_error "Missing required arguments"
    usage
fi

print_info "Deploying qscanner VM..."
echo "Resource Group: $RESOURCE_GROUP"
echo "Location: $LOCATION"
echo "VM Name: $VM_NAME"
echo "VM Size: $VM_SIZE"
echo ""

# Create VM
print_info "Creating Ubuntu VM..."

VM_CREATE_CMD="az vm create \
    --resource-group $RESOURCE_GROUP \
    --name $VM_NAME \
    --image Ubuntu2204 \
    --size $VM_SIZE \
    --admin-username azureuser \
    --generate-ssh-keys \
    --public-ip-address \"\" \
    --nsg \"\""

if [ -n "$VNET_NAME" ]; then
    VM_CREATE_CMD="$VM_CREATE_CMD --vnet-name $VNET_NAME"
fi

eval $VM_CREATE_CMD

print_success "VM created: $VM_NAME"

# Install Docker and qscanner
print_info "Installing Docker and qscanner..."

INSTALL_SCRIPT=$(cat <<'EOF'
#!/bin/bash
set -e

# Update system
sudo apt-get update

# Install Docker
sudo apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release

# Add Docker GPG key
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

# Add Docker repository
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker Engine
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io

# Start Docker
sudo systemctl start docker
sudo systemctl enable docker

# Add current user to docker group
sudo usermod -aG docker azureuser

# Download qscanner
wget -O /tmp/qscanner https://qualysguard.qg2.apps.qualys.com/csdownload/qscanner
sudo mv /tmp/qscanner /usr/local/bin/qscanner
sudo chmod +x /usr/local/bin/qscanner

# Verify installation
docker --version
/usr/local/bin/qscanner --version || true

echo "Installation complete!"
EOF
)

az vm run-command invoke \
    --resource-group $RESOURCE_GROUP \
    --name $VM_NAME \
    --command-id RunShellScript \
    --scripts "$INSTALL_SCRIPT"

print_success "Docker and qscanner installed"

# Configure qscanner credentials if provided
if [ -n "$QUALYS_USER" ] && [ -n "$QUALYS_PASS" ]; then
    print_info "Configuring qscanner credentials..."

    CRED_SCRIPT=$(cat <<EOF
echo "export QUALYS_USERNAME='$QUALYS_USER'" | sudo tee -a /etc/environment
echo "export QUALYS_PASSWORD='$QUALYS_PASS'" | sudo tee -a /etc/environment
EOF
)

    az vm run-command invoke \
        --resource-group $RESOURCE_GROUP \
        --name $VM_NAME \
        --command-id RunShellScript \
        --scripts "$CRED_SCRIPT"

    print_success "Credentials configured"
fi

# Get VM private IP
VM_IP=$(az vm show \
    --resource-group $RESOURCE_GROUP \
    --name $VM_NAME \
    --show-details \
    --query "privateIps" \
    --output tsv)

print_success "qscanner VM deployment complete!"
echo ""
echo "VM Details:"
echo "  Name: $VM_NAME"
echo "  Private IP: $VM_IP"
echo "  Resource Group: $RESOURCE_GROUP"
echo ""
echo "To connect to the VM:"
echo "  az vm run-command invoke -g $RESOURCE_GROUP -n $VM_NAME --command-id RunShellScript --scripts 'qscanner --version'"
echo ""
echo "To scan an image:"
echo "  az vm run-command invoke -g $RESOURCE_GROUP -n $VM_NAME --command-id RunShellScript --scripts 'qscanner --image nginx:latest --tag deployment=aci'"
