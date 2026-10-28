#!/usr/bin/env bash
# Replace the placeholder tokens in this repo with your real values (run once, before the first commit).
#   ./scripts/configure.sh                       -> interactive
#   AWS_ACCOUNT_ID=111122223333 ... ./scripts/configure.sh   -> non-interactive
set -euo pipefail
cd "$(dirname "$0")/.."

ask() { # name default prompt
  local var=$1 def=$2 prompt=$3
  if [ -z "${!var:-}" ]; then read -r -p "$prompt [$def]: " val; printf -v "$var" '%s' "${val:-$def}"; fi
}
ask AWS_ACCOUNT_ID "" "AWS account id (12 digits)"
ask AWS_REGION     "ap-south-1" "AWS region"
ask CLUSTER_NAME   "cardsplit-eks" "EKS cluster name"
ask GIT_REPO_URL   "" "HTTPS URL of THIS repo (e.g. https://github.com/you/cardsplit-gitops.git)"
ask ADMIN_CIDR     "0.0.0.0/0" "CIDR allowed to reach ArgoCD/Grafana/Kiali/Jaeger/Splunk (use YOUR_IP/32!)"

[[ "$AWS_ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || { echo "AWS account id must be 12 digits"; exit 1; }
[[ "$GIT_REPO_URL" =~ ^https:// ]]     || { echo "Repo URL must start with https://"; exit 1; }
GIT_REPO_HOST_PATH=${GIT_REPO_URL#https://}

files=$(grep -rIl '__[A-Z_]\+__' --exclude-dir=.git --exclude=configure.sh . || true)
for f in $files; do
  sed -i \
    -e "s|__AWS_ACCOUNT_ID__|$AWS_ACCOUNT_ID|g" \
    -e "s|__AWS_REGION__|$AWS_REGION|g" \
    -e "s|__CLUSTER_NAME__|$CLUSTER_NAME|g" \
    -e "s|__GIT_REPO_HOST_PATH__|$GIT_REPO_HOST_PATH|g" \
    -e "s|__GIT_REPO_URL__|$GIT_REPO_URL|g" \
    -e "s|__ADMIN_CIDR__|$ADMIN_CIDR|g" "$f"
done
echo "Configured. Remaining tokens (should be none):"
grep -rIn '__[A-Z_]\+__' --exclude-dir=.git --exclude=configure.sh . || echo "  none"
if [ "$ADMIN_CIDR" = "0.0.0.0/0" ]; then echo "WARNING: admin UIs are open to the whole internet. Restrict ADMIN_CIDR when you can."; fi
