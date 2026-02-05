#!/bin/bash
set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
KEYS_DIR="$PROJECT_DIR/keys"
POLICIES_DIR="$PROJECT_DIR/policies/kyverno"

echo -e "${YELLOW}Injecting public key into Kyverno policies...${NC}"

# Check if key exists
if [[ ! -f "$KEYS_DIR/cosign.pub" ]]; then
    echo -e "${RED}Error: keys/cosign.pub not found${NC}"
    echo -e "Run ${YELLOW}make setup${NC} first to generate keys"
    exit 1
fi

# Read the public key
PUB_KEY=$(cat "$KEYS_DIR/cosign.pub")

echo -e "Public key found:"
echo -e "${GREEN}$PUB_KEY${NC}"
echo ""

# Process each policy file
for policy_file in "$POLICIES_DIR"/*.yaml; do
    filename=$(basename "$policy_file")

    # Check if file has placeholder
    if grep -q "# REPLACE THIS\|# Replace with your cosign.pub" "$policy_file"; then
        echo -e "Updating ${YELLOW}$filename${NC}..."

        # Create a temporary file with the updated content
        # Using awk for reliable multi-line replacement
        awk -v key="$PUB_KEY" '
        /publicKeys: \|/ {
            print
            getline  # skip the next line (placeholder comment or old key)
            # Skip any existing key content until we hit a line that is not indented more
            while (getline > 0 && /^[[:space:]]{20,}/) {
                # skip old key lines
            }
            # Print the new key with proper indentation
            indent = "                      "  # 22 spaces to match YAML structure
            n = split(key, lines, "\n")
            for (i = 1; i <= n; i++) {
                if (lines[i] != "") {
                    print indent lines[i]
                }
            }
            # Print the line we read that wasnt part of the key
            if (!/^[[:space:]]{20,}/) print
            next
        }
        { print }
        ' "$policy_file" > "$policy_file.tmp"

        mv "$policy_file.tmp" "$policy_file"
        echo -e "${GREEN}✓ Updated $filename${NC}"
    else
        echo -e "Skipping ${filename} (no placeholder found or already updated)"
    fi
done

echo ""
echo -e "${GREEN}Done! Policies updated with your signing key.${NC}"
echo -e "You can now run: ${YELLOW}kubectl apply -f policies/kyverno/${NC}"
