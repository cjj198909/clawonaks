#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

echo "WARNING: This will destroy ALL OpenClaw resources"
read -r -p "Type 'yes' to confirm: " CONFIRM
[ "$CONFIRM" = "yes" ] || { echo "Aborted."; exit 1; }

echo "=== Uninstalling Helm release ==="
helm uninstall openclaw --namespace openclaw 2>/dev/null || echo "  No Helm release found, skipping."

echo "=== Deleting K8s namespace (catches orphaned resources) ==="
kubectl delete namespace openclaw --ignore-not-found

echo "=== Deleting Kata sandbox nodepool (managed outside Terraform) ==="
RG=$(cd "$ROOT_DIR/terraform" && terraform output -raw resource_group 2>/dev/null || echo "")
AKS_NAME=$(cd "$ROOT_DIR/terraform" && terraform output -raw aks_name 2>/dev/null || echo "")
if [[ -n "$RG" && -n "$AKS_NAME" ]] && az aks nodepool show --resource-group "$RG" --cluster-name "$AKS_NAME" --name sandboxv6 &>/dev/null; then
  echo "  Deleting sandboxv6 nodepool (this may take a few minutes)..."
  az aks nodepool delete --resource-group "$RG" --cluster-name "$AKS_NAME" --name sandboxv6 --no-wait
  echo "  Nodepool deletion initiated (--no-wait)."
else
  echo "  Sandbox nodepool not found or Terraform outputs unavailable, skipping."
fi

echo "=== Destroying Terraform infrastructure ==="
cd "$ROOT_DIR/terraform"
terraform destroy -auto-approve

echo "=== Done ==="
