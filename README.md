# Supply Chain Security Demo

End-to-end demonstration of Kubernetes admission control for container supply chain security.

## What This Demo Shows

This demo demonstrates blocking deployments based on:

1. **Unsigned containers** - Images without cosign signatures are blocked
2. **Images not from approved pipelines** - Only images built through Harness (or demo script) are allowed
3. **Images with critical vulnerabilities** - Images with > 1 critical CVE without a fix are blocked

## Architecture

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   Harness CI    │     │  Container      │     │   Kubernetes    │
│   Pipeline      │────▶│  Registry       │────▶│   Cluster       │
└─────────────────┘     └─────────────────┘     └─────────────────┘
        │                       │                       │
        ▼                       ▼                       ▼
   ┌─────────┐            ┌─────────┐            ┌─────────┐
   │  Build  │            │ Signed  │            │ Kyverno │
   │  Scan   │            │ Image + │            │ Admission│
   │  Sign   │            │ Attests │            │ Control │
   │  Attest │            └─────────┘            └─────────┘
   └─────────┘
```

## Prerequisites

- Docker Desktop with Kubernetes enabled (or any K8s cluster)
- kubectl
- Helm 3.x
- bash

## Quick Start

```bash
# 1. Clone and enter the repo
cd supply-chain-demo

# 2. Run everything
make all

# Or step by step:
make setup     # Install tools, generate keys, install Kyverno
make build     # Build, scan, sign, and attest images
make policies  # Apply Kyverno policies
make demo      # Run the interactive demo
```

## Directory Structure

```
supply-chain-demo/
├── app/                          # Sample application
│   ├── main.go                   # Simple Go HTTP server
│   ├── go.mod
│   ├── Dockerfile                # Secure image (Alpine 3.20)
│   └── Dockerfile.vulnerable     # Intentionally vulnerable (Alpine 3.14)
├── scripts/
│   ├── setup.sh                  # Install tools, generate keys
│   ├── build-sign-attest.sh      # Build, scan, sign images
│   └── demo.sh                   # Interactive demo script
├── policies/
│   └── kyverno/
│       ├── supply-chain-policy.yaml    # Main policy (combined)
│       ├── require-image-signature.yaml
│       ├── verify-vulnerability-scan.yaml
│       └── verify-pipeline-source.yaml
├── k8s/
│   ├── namespace.yaml
│   ├── deployment-secure.yaml       # ✓ Should deploy
│   ├── deployment-vulnerable.yaml   # ✗ Blocked (CVEs)
│   └── deployment-unsigned.yaml     # ✗ Blocked (no sig)
├── harness/
│   └── pipeline.yaml            # Harness pipeline reference
├── keys/                        # Generated signing keys (gitignored)
├── reports/                     # Scan reports (gitignored)
├── Makefile
└── README.md
```

## How It Works

### 1. Image Signing (cosign)

Images are signed using cosign with a static key pair:

```bash
# Sign an image
cosign sign --key keys/cosign.key \
  --tlog-upload=false \
  -a "pipeline=demo-build" \
  -a "scanner=grype" \
  -a "critical=0" \
  localhost:5000/supply-chain-demo:1.0.0

# Verify a signature
cosign verify --key keys/cosign.pub \
  localhost:5000/supply-chain-demo:1.0.0
```

### 2. Vulnerability Scanning (grype)

Images are scanned with Grype and results attached as attestations:

```bash
# Scan an image
grype localhost:5000/supply-chain-demo:1.0.0 -o json > vulns.json

# Attach attestation
cosign attest --key keys/cosign.key \
  --predicate vuln-predicate.json \
  --type vuln \
  localhost:5000/supply-chain-demo:1.0.0
```

### 3. Admission Control (Kyverno)

Kyverno policies verify images at deployment time:

```yaml
# Simplified policy logic
verifyImages:
  - imageReferences: ["localhost:5000/*"]
    attestors:
      - keys:
          publicKeys: |
            -----BEGIN PUBLIC KEY-----
            ...
            -----END PUBLIC KEY-----
    attestations:
      - predicateType: vuln
        conditions:
          - key: "{{ summary.criticalWithoutFix }}"
            operator: LessThanOrEquals
            value: "1"
```

## Demo Scenarios

| Scenario | Image | Expected Result | Reason |
|----------|-------|-----------------|--------|
| Unsigned | `:1.0.0-unsigned` | ✗ BLOCKED | No signature |
| Vulnerable | `:1.0.0-vulnerable` | ✗ BLOCKED | > 1 critical CVE without fix |
| Wrong pipeline | (simulated) | ✗ BLOCKED | Missing pipeline annotation |
| Compliant | `:1.0.0` | ✓ ALLOWED | Signed, scanned, compliant |

## Using with Harness

The `harness/pipeline.yaml` provides a reference Harness pipeline that:

1. Builds the container image
2. Generates SBOM with Syft
3. Scans with Grype
4. Fails the pipeline if > 1 critical CVE without fix
5. Signs the image with cosign
6. Attaches SBOM and vulnerability attestations
7. Deploys to EKS

### Required Harness Secrets

- `cosign_password` - Password for cosign private key
- `cosign_key` - Base64-encoded cosign private key (or mount as file)

### Required Connectors

- Docker registry connector
- Git repository connector
- Kubernetes cluster connector (for build infrastructure)

## Customization

### Change Registry

```bash
REGISTRY=your-registry.com make build
```

### Change Vulnerability Threshold

Edit `policies/kyverno/supply-chain-policy.yaml`:

```yaml
conditions:
  - key: "{{ summary.criticalWithoutFix }}"
    operator: LessThanOrEquals
    value: "0"  # Zero tolerance for unfixed criticals
```

### Add Your Own Registry Patterns

Edit the policy's `imageReferences`:

```yaml
imageReferences:
  - "localhost:5000/*"
  - "*.dkr.ecr.*.amazonaws.com/*"
  - "your-registry.com/*"
```

## Troubleshooting

### Policy not blocking images

1. Check Kyverno is running: `kubectl get pods -n kyverno`
2. Check policy is applied: `kubectl get clusterpolicy`
3. Verify the public key in policies matches `keys/cosign.pub`

### Signature verification fails

1. Ensure image was pushed to registry before signing
2. Verify with: `cosign verify --key keys/cosign.pub IMAGE`

### Local registry issues

```bash
# Start local registry
docker run -d -p 5000:5000 --name registry registry:2

# Check if running
docker ps | grep registry
```

## Clean Up

```bash
make clean
```

## Security Considerations

- **Keys**: The `keys/` directory is gitignored. Never commit private keys.
- **Registry**: For production, use a secure registry with proper authentication.
- **Policies**: Start with `validationFailureAction: Audit` before enforcing.
- **Transparency Log**: This demo disables Rekor (`--tlog-upload=false`). For production, consider enabling it.

## References

- [Cosign Documentation](https://docs.sigstore.dev/cosign/overview/)
- [Kyverno Image Verification](https://kyverno.io/docs/writing-policies/verify-images/)
- [Grype Scanner](https://github.com/anchore/grype)
- [Syft SBOM Generator](https://github.com/anchore/syft)
- [SLSA Framework](https://slsa.dev/)
