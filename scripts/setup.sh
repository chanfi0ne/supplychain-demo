#!/bin/bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Supply Chain Security Demo Setup ===${NC}"

# Check prerequisites
echo -e "\n${YELLOW}Checking prerequisites...${NC}"

command -v docker >/dev/null 2>&1 || { echo -e "${RED}Docker is required but not installed.${NC}"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo -e "${RED}kubectl is required but not installed.${NC}"; exit 1; }
command -v helm >/dev/null 2>&1 || { echo -e "${RED}Helm is required but not installed.${NC}"; exit 1; }

echo -e "${GREEN}✓ Docker, kubectl, and Helm are installed${NC}"

# Install cosign if not present
if ! command -v cosign &> /dev/null; then
    echo -e "\n${YELLOW}Installing cosign...${NC}"
    # For macOS
    if [[ "$OSTYPE" == "darwin"* ]]; then
        brew install cosign
    else
        # For Linux
        COSIGN_VERSION="v2.2.3"
        curl -sLO "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-amd64"
        chmod +x cosign-linux-amd64
        sudo mv cosign-linux-amd64 /usr/local/bin/cosign
    fi
fi
echo -e "${GREEN}✓ cosign installed: $(cosign version 2>&1 | head -1)${NC}"

# Install grype if not present
if ! command -v grype &> /dev/null; then
    echo -e "\n${YELLOW}Installing grype...${NC}"
    curl -sSfL https://raw.githubusercontent.com/anchore/grype/main/install.sh | sh -s -- -b /usr/local/bin
fi
echo -e "${GREEN}✓ grype installed: $(grype version 2>&1 | head -1)${NC}"

# Install syft if not present
if ! command -v syft &> /dev/null; then
    echo -e "\n${YELLOW}Installing syft...${NC}"
    curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b /usr/local/bin
fi
echo -e "${GREEN}✓ syft installed: $(syft version 2>&1 | head -1)${NC}"

# Create keys directory
KEYS_DIR="$(dirname "$0")/../keys"
mkdir -p "$KEYS_DIR"

# Generate cosign key pair if not exists
if [[ ! -f "$KEYS_DIR/cosign.key" ]]; then
    echo -e "\n${YELLOW}Generating cosign key pair...${NC}"
    cd "$KEYS_DIR"
    COSIGN_PASSWORD="" cosign generate-key-pair
    cd - > /dev/null
    echo -e "${GREEN}✓ Cosign keys generated in $KEYS_DIR${NC}"
else
    echo -e "${GREEN}✓ Cosign keys already exist in $KEYS_DIR${NC}"
fi

# Install Kyverno if not present in cluster
echo -e "\n${YELLOW}Checking Kyverno installation...${NC}"
if ! kubectl get ns kyverno &> /dev/null; then
    echo -e "${YELLOW}Installing Kyverno...${NC}"
    helm repo add kyverno https://kyverno.github.io/kyverno/ 2>/dev/null || true
    helm repo update
    helm install kyverno kyverno/kyverno \
        --namespace kyverno \
        --create-namespace \
        --set admissionController.replicas=1 \
        --set backgroundController.replicas=1 \
        --set cleanupController.replicas=1 \
        --set reportsController.replicas=1 \
        --wait
    echo -e "${GREEN}✓ Kyverno installed${NC}"
else
    echo -e "${GREEN}✓ Kyverno already installed${NC}"
fi

# Wait for Kyverno to be ready
echo -e "\n${YELLOW}Waiting for Kyverno to be ready...${NC}"
kubectl wait --for=condition=ready pod -l app.kubernetes.io/component=admission-controller -n kyverno --timeout=120s

echo -e "\n${GREEN}=== Setup Complete ===${NC}"
echo -e "Next steps:"
echo -e "  1. Run ${YELLOW}./scripts/build-sign-attest.sh${NC} to build and sign images"
echo -e "  2. Run ${YELLOW}kubectl apply -f policies/kyverno/${NC} to apply policies"
echo -e "  3. Run ${YELLOW}./scripts/demo.sh${NC} to see the demo"
