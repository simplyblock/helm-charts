#!/usr/bin/env bash
# Configures a Vault instance for SimplyBlock KMS.
# Run this against any Vault (HashiCorp Vault, OpenBao, or hosted) before
# pointing SimplyBlock at it.
set -euo pipefail

VAULT_CLI="${VAULT_CLI:-vault}"
VAULT_ADDR="${VAULT_ADDR:-}"
VAULT_CACERT="${VAULT_CACERT:-}"
VAULT_TOKEN="${VAULT_TOKEN:-}"
SB_NAMESPACE="${SB_NAMESPACE:-simplyblock}"
KMS_CA_CERT="${KMS_CA_CERT:-}"
CERT_ROLE="${CERT_ROLE:-simplyblock-webappapi}"
TRANSIT_MOUNT="${TRANSIT_MOUNT:-simplyblock/transit}"
KV_MOUNT="${KV_MOUNT:-simplyblock/kv}"

info() { echo "[INFO]  $*"; }
warn() { echo "[WARN]  $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

vault_cmd() {
  env VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN="$VAULT_TOKEN" \
      VAULT_CACERT="$VAULT_CACERT" "$VAULT_CLI" "$@"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<EOF
Usage: $0

Configures a Vault instance for SimplyBlock KMS. Creates the policy, cert auth
role, and enables the transit and KV secrets engines.

Requires the Vault CLI installed locally and the Vault to be reachable.

Env vars:
  VAULT_CLI         Vault CLI binary                   (default: vault)
  VAULT_ADDR        Vault server address               (required, e.g. https://vault.corp:8200)
  VAULT_CACERT      CA cert for Vault server TLS       (optional)
  VAULT_TOKEN       Vault token with admin permissions (required)
  SB_NAMESPACE      SimplyBlock Kubernetes namespace   (default: simplyblock)
  KMS_CA_CERT       SimplyBlock CA cert path           (default: extracted from simplyblock-ca-bundle-tls)
  CERT_ROLE         Vault cert auth role name          (default: simplyblock-webappapi)
  TRANSIT_MOUNT     Transit engine mount path          (default: simplyblock/transit)
  KV_MOUNT          KV engine mount path               (default: simplyblock/kv)

Example:
  VAULT_ADDR=https://vault.corp:8200 \\
  VAULT_TOKEN=s.xxxx \\
  VAULT_CACERT=/path/to/vault-ca.crt \\
  ./configure-kms.sh
EOF
  exit 0
fi

[[ -n "$VAULT_ADDR"  ]] || die "VAULT_ADDR is required"
[[ -n "$VAULT_TOKEN" ]] || die "VAULT_TOKEN is required"
command -v "$VAULT_CLI" &>/dev/null || die "$VAULT_CLI not found"
command -v kubectl      &>/dev/null || die "kubectl not found (needed to extract SimplyBlock CA)"

# ── Resolve SimplyBlock CA cert ────────────────────────────────────────────────
_TMP_CA=""
if [[ -z "$KMS_CA_CERT" ]]; then
  info "Extracting SimplyBlock CA from simplyblock-ca-bundle-tls in namespace $SB_NAMESPACE..."
  _TMP_CA="$(mktemp)"
  trap 'rm -f "$_TMP_CA"' EXIT
  kubectl -n "$SB_NAMESPACE" get secret simplyblock-ca-bundle-tls \
    -o jsonpath='{.data.ca\.crt}' | base64 -d > "$_TMP_CA"
  KMS_CA_CERT="$_TMP_CA"
fi

# ── Configure ──────────────────────────────────────────────────────────────────
info "Writing ${CERT_ROLE}-policy..."
vault_cmd policy write "${CERT_ROLE}-policy" - <<EOF
path "${TRANSIT_MOUNT}/keys/*" {
  capabilities = ["create", "update", "read", "delete"]
}
path "${TRANSIT_MOUNT}/datakey/plaintext/*" {
  capabilities = ["create", "update"]
}
path "${TRANSIT_MOUNT}/datakey/wrapped/*" {
  capabilities = ["create", "update"]
}
path "${TRANSIT_MOUNT}/encrypt/*" {
  capabilities = ["create", "update"]
}
path "${TRANSIT_MOUNT}/decrypt/*" {
  capabilities = ["create", "update"]
}
path "${KV_MOUNT}/*" {
  capabilities = ["create", "read", "update", "delete"]
}
path "${KV_MOUNT}/metadata/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
EOF

info "Enabling cert auth..."
vault_cmd auth enable cert || warn "cert auth already enabled, continuing..."
vault_cmd write "auth/cert/certs/${CERT_ROLE}" \
  certificate=@"$KMS_CA_CERT" \
  allowed_dns_sans="simplyblock-webappapi" \
  token_policies="${CERT_ROLE}-policy" \
  token_ttl=10m \
  token_max_ttl=30m

info "Enabling secrets engines..."
vault_cmd secrets enable -path="$TRANSIT_MOUNT" transit || warn "transit already enabled, continuing..."
vault_cmd secrets enable -path="$KV_MOUNT" kv           || warn "kv already enabled, continuing..."

# ── Done ───────────────────────────────────────────────────────────────────────
info "Done. Connect SimplyBlock to this Vault with:"
info "  cluster create --hashicorp-vault-url $VAULT_ADDR \\"
info "    --hashicorp-vault-transit-mount $TRANSIT_MOUNT \\"
info "    --hashicorp-vault-kv-mount $KV_MOUNT \\"
info "    --hashicorp-vault-cert-role $CERT_ROLE"
