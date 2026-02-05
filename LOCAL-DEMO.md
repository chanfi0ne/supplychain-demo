# Local Supply Chain Security Demo

Run all commands using Docker containers - no local tool installation required.

## Prerequisites

- Docker
- A terminal

---

## Setup

### Start Local Registry

```bash
docker run -d -p 5000:5000 --name registry registry:2
```

### Generate Signing Keys

```bash
docker run --rm -v $(pwd):/workspace -w /workspace \
  cgr.dev/chainguard/cosign generate-key-pair
```

This creates:
- `cosign.key` - Private key (keep secret)
- `cosign.pub` - Public key (distribute to verifiers)

---

## Build and Push Image

```bash
# Build the image
docker build -t localhost:5000/demo:v1 -f app/Dockerfile app/

# Push to local registry
docker push localhost:5000/demo:v1
```

---

## Sign the Image

```bash
docker run --rm -v $(pwd):/workspace --network host -e COSIGN_PASSWORD="" \
  cgr.dev/chainguard/cosign \
  sign --key /workspace/cosign.key --tlog-upload=false localhost:5000/demo:v1 -y
```

---

## Verify Signature

```bash
docker run --rm -v $(pwd):/workspace --network host \
  cgr.dev/chainguard/cosign \
  verify --key /workspace/cosign.pub localhost:5000/demo:v1
```

---

## Vulnerability Scanning with Grype

### Scan and Display Results

```bash
docker run --rm --network host anchore/grype:latest localhost:5000/demo:v1
```

### Scan and Save JSON Report

```bash
docker run --rm -v $(pwd):/workspace --network host \
  anchore/grype:latest localhost:5000/demo:v1 -o json=/workspace/vulns.json
```

### View Vulnerability Summary

```bash
cat vulns.json | jq '{
  critical: [.matches[] | select(.vulnerability.severity=="Critical")] | length,
  high: [.matches[] | select(.vulnerability.severity=="High")] | length,
  medium: [.matches[] | select(.vulnerability.severity=="Medium")] | length
}'
```

---

## Generate SBOM with Syft

### CycloneDX Format

```bash
docker run --rm -v $(pwd):/workspace --network host \
  anchore/syft:latest localhost:5000/demo:v1 -o cyclonedx-json=/workspace/sbom.json
```

### SPDX Format

```bash
docker run --rm -v $(pwd):/workspace --network host \
  anchore/syft:latest localhost:5000/demo:v1 -o spdx-json=/workspace/sbom-spdx.json
```

### View SBOM Summary

```bash
cat sbom.json | jq '{
  components: .components | length,
  bomFormat: .bomFormat,
  specVersion: .specVersion
}'
```

---

## Attach Attestations

### Attach Vulnerability Attestation

```bash
# First generate the vuln scan if not already done
docker run --rm -v $(pwd):/workspace --network host \
  anchore/grype:latest localhost:5000/demo:v1 -o json=/workspace/vulns.json

# Attach as attestation
docker run --rm -v $(pwd):/workspace --network host -e COSIGN_PASSWORD="" \
  cgr.dev/chainguard/cosign \
  attest --key /workspace/cosign.key --tlog-upload=false \
  --predicate /workspace/vulns.json --type vuln localhost:5000/demo:v1 -y
```

### Attach SBOM Attestation

```bash
# First generate SBOM if not already done
docker run --rm -v $(pwd):/workspace --network host \
  anchore/syft:latest localhost:5000/demo:v1 -o cyclonedx-json=/workspace/sbom.json

# Attach as attestation
docker run --rm -v $(pwd):/workspace --network host -e COSIGN_PASSWORD="" \
  cgr.dev/chainguard/cosign \
  attest --key /workspace/cosign.key --tlog-upload=false \
  --predicate /workspace/sbom.json --type cyclonedx localhost:5000/demo:v1 -y
```

---

## Verify Attestations

### Verify Vulnerability Attestation

```bash
docker run --rm -v $(pwd):/workspace --network host \
  cgr.dev/chainguard/cosign \
  verify-attestation --key /workspace/cosign.pub --type vuln localhost:5000/demo:v1
```

### Verify SBOM Attestation

```bash
docker run --rm -v $(pwd):/workspace --network host \
  cgr.dev/chainguard/cosign \
  verify-attestation --key /workspace/cosign.pub --type cyclonedx localhost:5000/demo:v1
```

---

## Explore OCI Artifacts in Registry

### Using Crane

#### List All Tags (Shows Signatures and Attestations)

```bash
docker run --rm --network host cgr.dev/chainguard/crane ls localhost:5000/demo
```

Output shows:
```
v1
sha256-<digest>.sig    # Signature artifact
sha256-<digest>.att    # Attestation artifact
```

#### View Image Manifest

```bash
docker run --rm --network host cgr.dev/chainguard/crane manifest localhost:5000/demo:v1 | jq
```

#### View Signature Manifest

```bash
# Replace <digest> with actual digest from 'crane ls' output
docker run --rm --network host cgr.dev/chainguard/crane manifest localhost:5000/demo:sha256-<digest>.sig | jq
```

#### View Attestation Manifest

```bash
docker run --rm --network host cgr.dev/chainguard/crane manifest localhost:5000/demo:sha256-<digest>.att | jq
```

#### Get Image Digest

```bash
docker run --rm --network host cgr.dev/chainguard/crane digest localhost:5000/demo:v1
```

#### View Image Config

```bash
docker run --rm --network host cgr.dev/chainguard/crane config localhost:5000/demo:v1 | jq
```

### Using ORAS

#### Discover Referrers (Artifacts Attached to Image)

```bash
docker run --rm --network host ghcr.io/oras-project/oras:latest \
  discover localhost:5000/demo:v1 -o tree
```

#### List Referrers as JSON

```bash
docker run --rm --network host ghcr.io/oras-project/oras:latest \
  discover localhost:5000/demo:v1 -o json | jq
```

### Using Registry API Directly

#### List Repositories

```bash
curl -s http://localhost:5000/v2/_catalog | jq
```

#### List Tags for an Image

```bash
curl -s http://localhost:5000/v2/demo/tags/list | jq
```

#### Get Image Manifest

```bash
curl -s -H "Accept: application/vnd.oci.image.manifest.v1+json" \
  http://localhost:5000/v2/demo/manifests/v1 | jq
```

---

## Demo Scenarios

### Scenario 1: Unsigned Image (Should Fail Verification)

```bash
# Build and push without signing
docker build -t localhost:5000/demo:unsigned -f app/Dockerfile app/
docker push localhost:5000/demo:unsigned

# Try to verify - THIS WILL FAIL
docker run --rm -v $(pwd):/workspace --network host \
  cgr.dev/chainguard/cosign \
  verify --key /workspace/cosign.pub localhost:5000/demo:unsigned
```

### Scenario 2: Vulnerable Image

```bash
# Build vulnerable image
docker build -t localhost:5000/demo:vulnerable -f app/Dockerfile.vulnerable app/
docker push localhost:5000/demo:vulnerable

# Scan - will show critical CVEs
docker run --rm --network host anchore/grype:latest localhost:5000/demo:vulnerable

# Sign it anyway (for demo purposes)
docker run --rm -v $(pwd):/workspace --network host -e COSIGN_PASSWORD="" \
  cgr.dev/chainguard/cosign \
  sign --key /workspace/cosign.key --tlog-upload=false localhost:5000/demo:vulnerable -y
```

### Scenario 3: Compliant Image (Signed + Scanned + Attested)

```bash
# Build secure image
docker build -t localhost:5000/demo:secure -f app/Dockerfile app/
docker push localhost:5000/demo:secure

# Sign
docker run --rm -v $(pwd):/workspace --network host -e COSIGN_PASSWORD="" \
  cgr.dev/chainguard/cosign \
  sign --key /workspace/cosign.key --tlog-upload=false localhost:5000/demo:secure -y

# Scan and attest
docker run --rm -v $(pwd):/workspace --network host \
  anchore/grype:latest localhost:5000/demo:secure -o json=/workspace/vulns-secure.json

docker run --rm -v $(pwd):/workspace --network host -e COSIGN_PASSWORD="" \
  cgr.dev/chainguard/cosign \
  attest --key /workspace/cosign.key --tlog-upload=false \
  --predicate /workspace/vulns-secure.json --type vuln localhost:5000/demo:secure -y

# Verify everything
docker run --rm -v $(pwd):/workspace --network host \
  cgr.dev/chainguard/cosign \
  verify --key /workspace/cosign.pub localhost:5000/demo:secure

docker run --rm -v $(pwd):/workspace --network host \
  cgr.dev/chainguard/cosign \
  verify-attestation --key /workspace/cosign.pub --type vuln localhost:5000/demo:secure
```

---

## Cleanup

```bash
# Stop and remove registry
docker stop registry && docker rm registry

# Remove generated files
rm -f cosign.key cosign.pub vulns.json sbom.json
```

---

## Container Images Used

| Tool | Image | Purpose |
|------|-------|---------|
| cosign | `cgr.dev/chainguard/cosign` | Sign, verify, attest |
| grype | `anchore/grype:latest` | Vulnerability scanning |
| syft | `anchore/syft:latest` | SBOM generation |
| crane | `cgr.dev/chainguard/crane` | Registry inspection |
| oras | `ghcr.io/oras-project/oras:latest` | OCI artifact discovery |
| registry | `registry:2` | Local container registry |


```
# cosign (check latest version at github.com/sigstore/cosign/releases)
curl -sL https://github.com/sigstore/cosign/releases/download/v2.4.1/cosign-darwin-arm64 -o cosign  # macOS ARM
# or: cosign-darwin-amd64, cosign-linux-amd64, cosign-linux-arm64

# crane
curl -sL https://github.com/google/go-containerregistry/releases/download/v0.20.0/go-containerregistry_Darwin_arm64.tar.gz | tar xz crane
# or: Darwin_x86_64, Linux_x86_64, Linux_arm64

chmod +x cosign crane
```