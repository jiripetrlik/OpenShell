#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Connect the CLI to the gateway installed by install-openshell-kata.sh.
set -euo pipefail
umask 077

context=""
namespace=openshell
name=kind-kata
port=18080

usage() {
  cat <<'EOF'
Usage: scripts/connect-openshell-kata.sh [options]

  --context NAME     Kubernetes context (default: current context)
  --namespace NAME   OpenShell namespace (default: openshell)
  --name NAME        CLI gateway name (default: kind-kata)
  --port PORT        Local port (default: 18080)
  -h, --help         Show this help

Forwards the openshell Service to localhost and registers/selects the CLI
gateway over HTTP, matching install-openshell-kata.sh.
Keep this script running while using openshell in another terminal.
Ctrl+C stops the port-forward; the CLI registration remains.
Requires kubectl and openshell.
EOF
}

while (($#)); do
  case "$1" in
    --context|--namespace|--name|--port)
      if (($# < 2)) || [[ -z "$2" || "$2" == --* ]]; then
        echo "ERROR: $1 requires a value" >&2
        exit 2
      fi
      case "$1" in
        --context) context="$2" ;;
        --namespace) namespace="$2" ;;
        --name) name="$2" ;;
        --port) port="$2" ;;
      esac
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ ! "$port" =~ ^[0-9]{1,5}$ ]] || ((10#$port < 1 || 10#$port > 65535)); then
  echo "ERROR: --port must be between 1 and 65535" >&2
  exit 2
fi
port=$((10#$port))
if [[ ! "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
  echo "ERROR: --name must be a single gateway name using letters, digits, dots, underscores, or hyphens" >&2
  exit 2
fi
for tool in kubectl openshell; do
  command -v "$tool" >/dev/null || { echo "ERROR: $tool is required" >&2; exit 1; }
done

if [[ -z "$context" ]]; then
  context="$(kubectl config current-context)"
fi
kctl() { kubectl --context "$context" -n "$namespace" "$@"; }
temp_dir="$(mktemp -d)"
forward_pid=""
cleanup() {
  if [[ -n "$forward_pid" ]]; then
    kill "$forward_pid" 2>/dev/null || true
    wait "$forward_pid" 2>/dev/null || true
  fi
  rm -f "$temp_dir/forward.log"
  rmdir "$temp_dir" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

kctl port-forward --address 127.0.0.1 svc/openshell "${port}:8080" > "$temp_dir/forward.log" 2>&1 &
forward_pid=$!
ready=false
for ((attempt=0; attempt<30; attempt++)); do
  if ! kill -0 "$forward_pid" 2>/dev/null; then
    cat "$temp_dir/forward.log" >&2
    echo "ERROR: port-forward exited before becoming ready" >&2
    exit 1
  fi
  if [[ "$(< "$temp_dir/forward.log")" == *"Forwarding from 127.0.0.1:${port} ->"* ]]; then
    ready=true
    break
  fi
  sleep 1
done
if [[ "$ready" != true ]]; then
  cat "$temp_dir/forward.log" >&2
  echo "ERROR: port-forward did not become ready within 30 seconds" >&2
  exit 1
fi

# This invocation targets the selected cluster even if other gateway overrides exist.
unset OPENSHELL_GATEWAY_ENDPOINT OPENSHELL_GATEWAY_INSECURE OPENSHELL_LOCAL_TLS_DIR
openshell gateway add "http://127.0.0.1:${port}" --local --name "$name"
openshell --gateway "$name" status

echo "Connected. In another terminal: openshell --gateway ${name} status"
echo "Keep this terminal open; press Ctrl+C to stop the port-forward."
wait "$forward_pid"
