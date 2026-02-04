#!/bin/bash
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
KEYS_DIR="$PROJECT_DIR/keys"
REPORTS_DIR="$PROJECT_DIR/reports"

# Configuration - change this to your registry
REGISTRY="${REGISTRY:-localhost:5000}"
IMAGE_NAME="${IMAGE_NAME:-supply-chain-demo}"
VERSION="${VERSION:-1.0.0}"

mkdir -p "$REPORTS_DIR"

echo -e "${GREEN}=== Build, Sign, and Attest ===${NC}"
echo -e "Registry: ${BLUE}$REGISTRY${NC}"
echo -e "Image: ${BLUE}$IMAGE_NAME${NC}"
echo -e "Version: ${BLUE}$VERSION${NC}"

# Function to build, scan, sign, and attest an image
build_and_process() {
    local dockerfile=$1
    local tag_suffix=$2
    local image_tag="$REGISTRY/$IMAGE_NAME:$VERSION$tag_suffix"

    echo -e "\n${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}Processing: $image_tag${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # Build
    echo -e "\n${BLUE}[1/5] Building image...${NC}"
    docker build -t "$image_tag" -f "$PROJECT_DIR/app/$dockerfile" "$PROJECT_DIR/app"
    echo -e "${GREEN}✓ Built $image_tag${NC}"

    # Push to registry (required for signing)
    echo -e "\n${BLUE}[2/5] Pushing to registry...${NC}"
    docker push "$image_tag"
    echo -e "${GREEN}✓ Pushed to registry${NC}"

    # Get the image digest
    DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "$image_tag" 2>/dev/null || \
             docker inspect --format='{{.Id}}' "$image_tag")
    echo -e "Digest: ${BLUE}$DIGEST${NC}"

    # Generate SBOM
    echo -e "\n${BLUE}[3/5] Generating SBOM with Syft...${NC}"
    syft "$image_tag" -o cyclonedx-json > "$REPORTS_DIR/sbom$tag_suffix.json"
    echo -e "${GREEN}✓ SBOM saved to reports/sbom$tag_suffix.json${NC}"

    # Scan for vulnerabilities
    echo -e "\n${BLUE}[4/5] Scanning with Grype...${NC}"
    grype "$image_tag" -o json > "$REPORTS_DIR/vulns$tag_suffix.json" || true

    # Parse vulnerability counts
    CRITICAL=$(jq '[.matches[] | select(.vulnerability.severity=="Critical")] | length' "$REPORTS_DIR/vulns$tag_suffix.json")
    HIGH=$(jq '[.matches[] | select(.vulnerability.severity=="High")] | length' "$REPORTS_DIR/vulns$tag_suffix.json")
    MEDIUM=$(jq '[.matches[] | select(.vulnerability.severity=="Medium")] | length' "$REPORTS_DIR/vulns$tag_suffix.json")

    # Count critical vulns without fixes
    CRITICAL_NO_FIX=$(jq '[.matches[] | select(.vulnerability.severity=="Critical" and .vulnerability.fix.state=="not-fixed")] | length' "$REPORTS_DIR/vulns$tag_suffix.json")

    echo -e "Vulnerabilities found:"
    echo -e "  Critical: ${RED}$CRITICAL${NC} (${RED}$CRITICAL_NO_FIX without fix${NC})"
    echo -e "  High: ${YELLOW}$HIGH${NC}"
    echo -e "  Medium: ${BLUE}$MEDIUM${NC}"

    # Create vulnerability attestation predicate
    cat > "$REPORTS_DIR/vuln-predicate$tag_suffix.json" << EOF
{
  "scanner": "grype",
  "scanTimestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "image": "$image_tag",
  "summary": {
    "critical": $CRITICAL,
    "criticalWithoutFix": $CRITICAL_NO_FIX,
    "high": $HIGH,
    "medium": $MEDIUM
  },
  "passesPolicy": $([ "$CRITICAL_NO_FIX" -le 1 ] && echo "true" || echo "false")
}
EOF

    # Sign the image
    echo -e "\n${BLUE}[5/5] Signing and attesting...${NC}"
    COSIGN_PASSWORD="" cosign sign --key "$KEYS_DIR/cosign.key" \
        --tlog-upload=false \
        -a "scanner=grype" \
        -a "critical=$CRITICAL" \
        -a "critical_no_fix=$CRITICAL_NO_FIX" \
        -a "pipeline=demo-build" \
        "$image_tag" -y
    echo -e "${GREEN}✓ Image signed${NC}"

    # Attach SBOM attestation
    COSIGN_PASSWORD="" cosign attest --key "$KEYS_DIR/cosign.key" \
        --tlog-upload=false \
        --predicate "$REPORTS_DIR/sbom$tag_suffix.json" \
        --type cyclonedx \
        "$image_tag" -y
    echo -e "${GREEN}✓ SBOM attestation attached${NC}"

    # Attach vulnerability attestation
    COSIGN_PASSWORD="" cosign attest --key "$KEYS_DIR/cosign.key" \
        --tlog-upload=false \
        --predicate "$REPORTS_DIR/vuln-predicate$tag_suffix.json" \
        --type vuln \
        "$image_tag" -y
    echo -e "${GREEN}✓ Vulnerability attestation attached${NC}"

    echo -e "\n${GREEN}✓ Complete: $image_tag${NC}"
}

# Check if local registry is running
if [[ "$REGISTRY" == "localhost:5000" ]]; then
    if ! docker ps | grep -q registry; then
        echo -e "\n${YELLOW}Starting local registry...${NC}"
        docker run -d -p 5000:5000 --name registry --restart=always registry:2 2>/dev/null || true
        sleep 2
    fi
fi

# Build both images
build_and_process "Dockerfile" ""                    # Secure image
build_and_process "Dockerfile.vulnerable" "-vulnerable"  # Vulnerable image

# Also build an unsigned image for demo
echo -e "\n${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}Building unsigned image for demo...${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
UNSIGNED_TAG="$REGISTRY/$IMAGE_NAME:$VERSION-unsigned"
docker build -t "$UNSIGNED_TAG" -f "$PROJECT_DIR/app/Dockerfile" "$PROJECT_DIR/app"
docker push "$UNSIGNED_TAG"
echo -e "${GREEN}✓ Unsigned image: $UNSIGNED_TAG${NC}"

echo -e "\n${GREEN}=== Build Complete ===${NC}"
echo -e "\nImages created:"
echo -e "  ${GREEN}✓ $REGISTRY/$IMAGE_NAME:$VERSION${NC} (signed, secure)"
echo -e "  ${YELLOW}⚠ $REGISTRY/$IMAGE_NAME:$VERSION-vulnerable${NC} (signed, has critical CVEs)"
echo -e "  ${RED}✗ $REGISTRY/$IMAGE_NAME:$VERSION-unsigned${NC} (not signed)"
echo -e "\nReports saved to: $REPORTS_DIR/"
