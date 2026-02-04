#!/bin/bash
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

pause() {
    echo -e "\n${CYAN}Press Enter to continue...${NC}"
    read -r
}

header() {
    echo -e "\n${BOLD}${BLUE}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}  $1${NC}"
    echo -e "${BOLD}${BLUE}════════════════════════════════════════════════════════════════${NC}\n"
}

echo -e "${BOLD}${GREEN}"
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║     SUPPLY CHAIN SECURITY DEMO                                ║"
echo "║     Kubernetes Admission Control with Kyverno                 ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Check prerequisites
echo -e "${YELLOW}Checking prerequisites...${NC}"
kubectl cluster-info > /dev/null 2>&1 || { echo -e "${RED}Cannot connect to Kubernetes cluster${NC}"; exit 1; }
kubectl get ns kyverno > /dev/null 2>&1 || { echo -e "${RED}Kyverno not installed. Run setup.sh first${NC}"; exit 1; }
echo -e "${GREEN}✓ Connected to cluster, Kyverno is running${NC}"

pause

# ═══════════════════════════════════════════════════════════════
header "SCENARIO 1: Deploy UNSIGNED Image"
# ═══════════════════════════════════════════════════════════════

echo -e "${YELLOW}Attempting to deploy an unsigned container image...${NC}"
echo -e "Image: ${BLUE}localhost:5000/supply-chain-demo:1.0.0-unsigned${NC}"
echo ""
echo -e "Expected result: ${RED}BLOCKED${NC} - No signature found"
echo ""

pause

echo -e "${CYAN}$ kubectl apply -f k8s/deployment-unsigned.yaml${NC}"
if kubectl apply -f "$PROJECT_DIR/k8s/deployment-unsigned.yaml" 2>&1; then
    echo -e "\n${RED}✗ Unexpected: Deployment was allowed!${NC}"
else
    echo -e "\n${GREEN}✓ Deployment BLOCKED as expected!${NC}"
    echo -e "${GREEN}  Reason: Image signature verification failed${NC}"
fi

pause

# ═══════════════════════════════════════════════════════════════
header "SCENARIO 2: Deploy Image with CRITICAL VULNERABILITIES"
# ═══════════════════════════════════════════════════════════════

echo -e "${YELLOW}Attempting to deploy image with critical vulnerabilities...${NC}"
echo -e "Image: ${BLUE}localhost:5000/supply-chain-demo:1.0.0-vulnerable${NC}"
echo ""

# Show vulnerability summary
if [[ -f "$PROJECT_DIR/reports/vulns-vulnerable.json" ]]; then
    CRITICAL=$(jq '[.matches[] | select(.vulnerability.severity=="Critical")] | length' "$PROJECT_DIR/reports/vulns-vulnerable.json")
    CRITICAL_NO_FIX=$(jq '[.matches[] | select(.vulnerability.severity=="Critical" and .vulnerability.fix.state=="not-fixed")] | length' "$PROJECT_DIR/reports/vulns-vulnerable.json")
    echo -e "Vulnerability scan results:"
    echo -e "  Critical: ${RED}$CRITICAL${NC}"
    echo -e "  Critical without fix: ${RED}$CRITICAL_NO_FIX${NC}"
    echo ""
fi

echo -e "Policy: Block if > 1 critical vulnerability without fix"
echo -e "Expected result: ${RED}BLOCKED${NC} - Too many unfixed critical vulnerabilities"
echo ""

pause

echo -e "${CYAN}$ kubectl apply -f k8s/deployment-vulnerable.yaml${NC}"
if kubectl apply -f "$PROJECT_DIR/k8s/deployment-vulnerable.yaml" 2>&1; then
    echo -e "\n${RED}✗ Unexpected: Deployment was allowed!${NC}"
else
    echo -e "\n${GREEN}✓ Deployment BLOCKED as expected!${NC}"
    echo -e "${GREEN}  Reason: Image has too many critical vulnerabilities without fixes${NC}"
fi

pause

# ═══════════════════════════════════════════════════════════════
header "SCENARIO 3: Deploy Image NOT from Approved Pipeline"
# ═══════════════════════════════════════════════════════════════

echo -e "${YELLOW}Attempting to deploy image built outside approved pipeline...${NC}"
echo ""
echo -e "The supply chain policy requires images to have a 'pipeline' annotation"
echo -e "matching 'demo-build' or 'harness-*'"
echo ""
echo -e "An image signed without the pipeline annotation would be blocked."
echo -e "${CYAN}(Simulated - our demo images include the annotation)${NC}"

pause

# ═══════════════════════════════════════════════════════════════
header "SCENARIO 4: Deploy COMPLIANT Image"
# ═══════════════════════════════════════════════════════════════

echo -e "${YELLOW}Deploying a fully compliant image...${NC}"
echo -e "Image: ${BLUE}localhost:5000/supply-chain-demo:1.0.0${NC}"
echo ""
echo -e "This image:"
echo -e "  ${GREEN}✓${NC} Is signed with cosign"
echo -e "  ${GREEN}✓${NC} Has vulnerability attestation"
echo -e "  ${GREEN}✓${NC} Has ≤ 1 critical vulnerability without fix"
echo -e "  ${GREEN}✓${NC} Was built through approved pipeline"
echo ""
echo -e "Expected result: ${GREEN}ALLOWED${NC}"
echo ""

pause

echo -e "${CYAN}$ kubectl apply -f k8s/deployment-secure.yaml${NC}"
if kubectl apply -f "$PROJECT_DIR/k8s/deployment-secure.yaml" 2>&1; then
    echo -e "\n${GREEN}✓ Deployment ALLOWED as expected!${NC}"

    echo -e "\n${YELLOW}Waiting for pod to be ready...${NC}"
    kubectl wait --for=condition=ready pod -l app=demo-app,version=secure -n demo --timeout=60s

    echo -e "\n${GREEN}Pod is running:${NC}"
    kubectl get pods -n demo -l app=demo-app,version=secure
else
    echo -e "\n${RED}✗ Unexpected: Deployment was blocked!${NC}"
fi

pause

# ═══════════════════════════════════════════════════════════════
header "VERIFICATION: Check Policy Reports"
# ═══════════════════════════════════════════════════════════════

echo -e "${YELLOW}Checking Kyverno policy reports...${NC}"
echo ""

echo -e "${CYAN}Policy violations:${NC}"
kubectl get policyreport -n demo -o wide 2>/dev/null || echo "No policy reports found"

echo ""
echo -e "${CYAN}Cluster-wide policy reports:${NC}"
kubectl get clusterpolicyreport -o wide 2>/dev/null || echo "No cluster policy reports found"

pause

# ═══════════════════════════════════════════════════════════════
header "CLEANUP"
# ═══════════════════════════════════════════════════════════════

echo -e "${YELLOW}Clean up demo resources?${NC}"
read -p "Delete demo deployments? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    kubectl delete -f "$PROJECT_DIR/k8s/deployment-secure.yaml" --ignore-not-found
    echo -e "${GREEN}✓ Cleanup complete${NC}"
fi

echo -e "\n${BOLD}${GREEN}"
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║     DEMO COMPLETE                                             ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

echo -e "Summary of what was demonstrated:"
echo -e "  ${RED}✗${NC} Unsigned images are blocked"
echo -e "  ${RED}✗${NC} Images with > 1 critical unfixed CVE are blocked"
echo -e "  ${RED}✗${NC} Images not from approved pipeline are blocked"
echo -e "  ${GREEN}✓${NC} Compliant images are allowed to deploy"
