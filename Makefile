.PHONY: setup build sign deploy demo clean all help

REGISTRY ?= localhost:5000
IMAGE_NAME ?= supply-chain-demo
VERSION ?= 1.0.0

help:
	@echo "Supply Chain Security Demo"
	@echo ""
	@echo "Usage:"
	@echo "  make setup      - Install tools and generate signing keys"
	@echo "  make build      - Build, scan, sign, and attest images"
	@echo "  make policies   - Apply Kyverno policies"
	@echo "  make demo       - Run the interactive demo"
	@echo "  make clean      - Clean up demo resources"
	@echo "  make all        - Run setup, build, policies, and demo"
	@echo ""
	@echo "Configuration:"
	@echo "  REGISTRY=$(REGISTRY)"
	@echo "  IMAGE_NAME=$(IMAGE_NAME)"
	@echo "  VERSION=$(VERSION)"

setup:
	@chmod +x scripts/*.sh
	@./scripts/setup.sh

build:
	@REGISTRY=$(REGISTRY) IMAGE_NAME=$(IMAGE_NAME) VERSION=$(VERSION) ./scripts/build-sign-attest.sh

policies: generate-policy
	@echo "Applying Kyverno policies..."
	@kubectl apply -f k8s/namespace.yaml
	@kubectl apply -f policies/kyverno/supply-chain-policy-final.yaml

generate-policy:
	@./scripts/generate-policy.sh

demo:
	@./scripts/demo.sh

clean:
	@echo "Cleaning up..."
	@kubectl delete -f k8s/ --ignore-not-found 2>/dev/null || true
	@kubectl delete -f policies/kyverno/supply-chain-policy.yaml --ignore-not-found 2>/dev/null || true
	@docker stop registry 2>/dev/null || true
	@docker rm registry 2>/dev/null || true
	@rm -rf reports/
	@echo "Cleanup complete"

all: setup build policies demo
