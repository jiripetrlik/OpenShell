#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Install the published OpenShell chart into an existing Kata-enabled kind cluster.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
namespace=openshell
version=0.0.0-dev
runtime_class=kata-qemu
chart=oci://ghcr.io/nvidia/openshell/helm-chart

usage() {
  cat <<'EOF'
Usage: scripts/install-openshell-kata.sh [options]

  --namespace NAME   Release namespace (default: openshell)
  --version VERSION  Published chart version (default: 0.0.0-dev)
  -h, --help         Show this help

Installs release "openshell" with kata-qemu as the default workload runtime.
Uses the current Kubernetes context. Fails if the release already exists.
Matches the release canary's local settings: TLS disabled, unauthenticated
user access enabled, and anonymous telemetry disabled.
Requires an installed kata-qemu RuntimeClass, default storage, an enforcing
NetworkPolicy implementation, kubectl, Helm, and cluster-admin permissions.
Installs Agent Sandbox v1.0.3 when its Sandbox CRD is missing. An existing
Agent Sandbox installation is retained. Override the dependency version with
AGENT_SANDBOX_VERSION. The default chart version is a floating development
release; use --version to pin a published release.
EOF
}

while (($#)); do
  case "$1" in
    --namespace|--version)
      if (($# < 2)) || [[ -z "$2" || "$2" == --* ]]; then
        echo "ERROR: $1 requires a value" >&2
        exit 2
      fi
      case "$1" in
        --namespace) namespace="$2" ;;
        --version) version="$2" ;;
      esac
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for tool in kubectl helm; do
  command -v "$tool" >/dev/null || { echo "ERROR: $tool is required" >&2; exit 1; }
done

kctl() { kubectl "$@"; }
context="$(kubectl config current-context)"

echo "Installing OpenShell ${version} on ${context}, namespace ${namespace}, runtime ${runtime_class}"
# Check the selected cluster and artifact before changing any cluster resources.
kctl get runtimeclass "$runtime_class" >/dev/null
kctl wait --for=condition=Ready nodes --all --timeout=60s
helm show chart "$chart" --version "$version" >/dev/null

if [[ -z "$(kctl get crd sandboxes.agents.x-k8s.io --ignore-not-found -o name)" ]]; then
  bash "${ROOT}/e2e/support/install-agent-sandbox.sh"
else
  served_versions="$(kctl get crd sandboxes.agents.x-k8s.io \
    -o 'jsonpath={range .spec.versions[?(@.served==true)]}{.name}{" "}{end}')"
  if [[ " $served_versions " != *" v1beta1 "* && " $served_versions " != *" v1alpha1 "* ]]; then
    echo "ERROR: Agent Sandbox must serve v1beta1 or v1alpha1; found: ${served_versions}" >&2
    exit 1
  fi
  kctl wait --for=condition=Established crd/sandboxes.agents.x-k8s.io --timeout=120s
  kctl -n agent-sandbox-system rollout status deployment/agent-sandbox-controller --timeout=300s
fi

# Resource admission requires explicit operator approval even for the default class.
kctl label runtimeclass "$runtime_class" openshell.ai/sandbox-attachable=true --overwrite

helm install openshell "$chart" \
  --namespace "$namespace" --create-namespace \
  --version "$version" \
  --set-string "server.defaultRuntimeClassName=${runtime_class}" \
  --set server.disableTls=true \
  --set server.auth.allowUnauthenticatedUsers=true \
  --set server.telemetryEnabled=false \
  --wait --timeout 5m

echo "OpenShell installed. New workloads default to ${runtime_class}."
echo "Inspect the deployment: kubectl -n ${namespace} get pods,pvc"
echo "Connection instructions: helm -n ${namespace} get notes openshell"
