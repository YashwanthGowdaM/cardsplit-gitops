#!/usr/bin/env bash
# Replace the floating chart ranges (e.g. "70.*") in argocd/apps/*.yaml with the exact latest version
# that matches the range, so deployments are reproducible. Needs: helm, yq (mikefarah).
set -euo pipefail
cd "$(dirname "$0")/.."
for f in argocd/apps/*.yaml; do
  chart=$(yq '.spec.sources[0].chart // ""' "$f"); [ -z "$chart" ] && continue
  repo=$(yq '.spec.sources[0].repoURL' "$f"); rev=$(yq '.spec.sources[0].targetRevision' "$f")
  helm repo add tmp-pin "$repo" >/dev/null 2>&1 || true; helm repo update tmp-pin >/dev/null
  exact=$(helm search repo "tmp-pin/$chart" --version "$rev" -o json | yq '.[0].version')
  echo "$f: $chart $rev -> $exact"
  yq -i ".spec.sources[0].targetRevision = \"$exact\"" "$f"
  helm repo remove tmp-pin >/dev/null
done
