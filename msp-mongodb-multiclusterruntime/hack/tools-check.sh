#!/usr/bin/env bash
# hack/tools-check.sh — Assert required CLIs are present and the Docker daemon is reachable.
# Owner: k8s-expert
#
# Required (fatal if missing):  kubectl, kind, docker, helm
set -euo pipefail

MISSING=()

echo "==> tools-check: verifying required CLIs"
echo ""

# --- Standard CLIs ---
echo "  kubectl:"
if command -v kubectl >/dev/null 2>&1; then
  kubectl version --client 2>/dev/null || kubectl version --client --short 2>/dev/null || true
else
  echo "  [MISSING] kubectl"
  MISSING+=("kubectl")
fi

echo ""
echo "  kind:"
if command -v kind >/dev/null 2>&1; then
  kind version
else
  echo "  [MISSING] kind"
  MISSING+=("kind")
fi

echo ""
echo "  docker:"
if command -v docker >/dev/null 2>&1; then
  docker version --format 'Client: {{.Client.Version}}  Server: {{.Server.Version}}' 2>/dev/null \
    || docker --version
else
  echo "  [MISSING] docker"
  MISSING+=("docker")
fi

echo ""
echo "  helm:"
if command -v helm >/dev/null 2>&1; then
  helm version --short
else
  echo "  [MISSING] helm"
  MISSING+=("helm")
fi

# --- Docker daemon health ---
echo ""
echo "==> Checking Docker daemon reachability"
if ! docker info >/dev/null 2>&1; then
  echo "  [ERROR] Docker daemon is not reachable. Is Docker running?"
  MISSING+=("docker-daemon")
else
  echo "  Docker daemon: OK"
fi

# --- Report ---
echo ""
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "==> tools-check: FAILED — missing required tools: ${MISSING[*]}"
  exit 1
fi

echo "==> tools-check: all required tools present"
