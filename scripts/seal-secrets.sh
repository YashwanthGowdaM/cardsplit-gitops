#!/usr/bin/env bash
# Turn the placeholder Secrets into encrypted SealedSecrets (safe to commit).
# Needs: kubectl (pointing at the cluster), kubeseal, and the sealed-secrets controller running
# (ArgoCD app "sealed-secrets", wave -3).  Run AFTER the controller is up, BEFORE the app/platform apps sync,
# or any time you want to rotate passwords.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v kubeseal >/dev/null || { echo "kubeseal not found"; exit 1; }

read -r -s -p "CardSplit ADMIN password (unlocks add/edit/delete in the UI): " ADMIN_PW; echo
read -r -s -p "PostgreSQL password (dev):  " DB_PW_DEV;  echo
read -r -s -p "PostgreSQL password (prod): " DB_PW_PROD; echo
read -r -s -p "Grafana admin password: " GRAFANA_PW; echo
read -r -s -p "Splunk admin password (min 8 chars): " SPLUNK_PW; echo
HEC_TOKEN=$(python3 -c 'import uuid;print(uuid.uuid4())')

seal() { # name namespace outfile key=value...
  local name=$1 ns=$2 out=$3; shift 3
  local args=()
  for kv in "$@"; do args+=(--from-literal="$kv"); done
  kubectl create secret generic "$name" -n "$ns" "${args[@]}" --dry-run=client -o yaml \
    | kubeseal --controller-name sealed-secrets-controller --controller-namespace kube-system --format yaml > "$out"
  echo "sealed: $out"
}
seal cardsplit-secrets cardsplit-dev  apps/cardsplit/overlays/dev/secret.yaml  DB_USER=cardsplit DB_PASSWORD="$DB_PW_DEV"  ADMIN_PASSWORD="$ADMIN_PW"
seal cardsplit-secrets cardsplit-prod apps/cardsplit/overlays/prod/secret.yaml DB_USER=cardsplit DB_PASSWORD="$DB_PW_PROD" ADMIN_PASSWORD="$ADMIN_PW"
seal grafana-admin     monitoring     platform/base/secrets/grafana-admin.yaml admin-user=admin admin-password="$GRAFANA_PW"
seal splunk-secrets    logging        platform/base/secrets/splunk-secrets.yaml SPLUNK_PASSWORD="$SPLUNK_PW" HEC_TOKEN="$HEC_TOKEN"
echo "Done. Review 'git diff', then commit + push."
