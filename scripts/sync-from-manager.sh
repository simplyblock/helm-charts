#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELM_CHARTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANAGER_DIR="${1:-$(cd "$HELM_CHARTS_DIR/../simplyblock-manager" && pwd)}"

CRD_SRC="$MANAGER_DIR/config/crd/bases"
CRD_DST="$HELM_CHARTS_DIR/charts/simplyblock-operator/crds"
RBAC_SRC="$MANAGER_DIR/config/rbac"
ROLES_DST="$HELM_CHARTS_DIR/charts/simplyblock-operator/templates/roles"

echo "Syncing from: $MANAGER_DIR"
echo ""

# ── CRDs ──────────────────────────────────────────────────────────────────────
echo "==> Syncing CRDs..."
for src in "$CRD_SRC"/storage.simplyblock.io_*.yaml; do
  name=$(basename "$src")
  cp "$src" "$CRD_DST/$name"
  echo "  copied: $name"
done

# ── Roles ─────────────────────────────────────────────────────────────────────
echo ""
echo "==> Syncing roles..."
mkdir -p "$ROLES_DST"

# Clear stale role files not present in the source
for dst in "$ROLES_DST"/*.yaml; do
  [ -f "$dst" ] || continue
  name=$(basename "$dst")
  [ -f "$RBAC_SRC/$name" ] || { rm "$dst"; echo "  removed (no longer in source): $name"; }
done

# Excluded: leader_election_role and role_binding are managed in simplyblock-operator.yaml
EXCLUDE="leader_election_role.yaml|leader_election_role_binding.yaml|role_binding.yaml|service_account.yaml|kustomization.yaml"

for src in "$RBAC_SRC"/*_role.yaml "$RBAC_SRC"/*_role_binding.yaml; do
  [ -f "$src" ] || continue
  name=$(basename "$src")
  echo "$name" | grep -qE "$EXCLUDE" && continue

  # Normalize: replace kustomize label with Helm, fix known typos
  sed \
    -e 's|app.kubernetes.io/managed-by: kustomize|app.kubernetes.io/managed-by: Helm|g' \
    -e 's|name: ssimplyblocktoragenode-editor-role|name: storagenode-editor-role|g' \
    "$src" > "$ROLES_DST/$name"
  echo "  copied: $name"
done

