#!/usr/bin/env bash
# Offline validation of the repository.
#   ./scripts/validate.sh            warn about placeholder secrets
#   ./scripts/validate.sh --strict   fail on placeholder secrets / unreplaced placeholder tokens (use before the first push)
set -uo pipefail
cd "$(dirname "$0")/.."
STRICT=${1:-}
rc=0

echo "== 1. YAML syntax"
python3 - <<'PY' || rc=1
import glob, sys, yaml
bad = 0
for f in glob.glob('**/*.y*ml', recursive=True):
    try: list(yaml.safe_load_all(open(f)))
    except Exception as e: print("  FAIL", f, e); bad += 1
print("  checked, failures:", bad); sys.exit(1 if bad else 0)
PY

echo "== 2. kustomize build (if kustomize is installed)"
if command -v kustomize >/dev/null; then
  for d in apps/cardsplit/overlays/dev apps/cardsplit/overlays/prod platform/base platform/istio/config platform/monitoring/extras platform/splunk platform/jaeger; do
    if kustomize build "$d" >/tmp/out.yaml 2>/tmp/err.txt; then echo "  OK   $d ($(grep -c '^kind:' /tmp/out.yaml) objects)"; else echo "  FAIL $d"; cat /tmp/err.txt; rc=1; fi
  done
else echo "  skipped (kustomize not installed)"; fi

echo "== 3. kubeconform (if installed)"
if command -v kubeconform >/dev/null && command -v kustomize >/dev/null; then
  for d in apps/cardsplit/overlays/dev apps/cardsplit/overlays/prod; do
    kustomize build "$d" | kubeconform -strict -ignore-missing-schemas -summary || rc=1
  done
else echo "  skipped"; fi

echo "== 4. Secrets / placeholders"
ph=$(grep -rIl 'CHANGE_ME' --exclude-dir=.git --exclude=validate.sh --exclude-dir=docs . || true)
if [ -n "$ph" ]; then echo "  placeholder secrets still present in:"; echo "$ph" | sed 's/^/    /'; [ "$STRICT" = "--strict" ] && rc=1; else echo "  none (good)"; fi
tok=$(grep -rIl '__[A-Z_]\+__' --exclude-dir=.git --exclude-dir=docs --exclude=configure.sh --exclude=validate.sh . || true)
if [ -n "$tok" ]; then echo "  unreplaced placeholder tokens in:"; echo "$tok" | sed 's/^/    /'; [ "$STRICT" = "--strict" ] && rc=1; else echo "  all tokens replaced"; fi

[ $rc -eq 0 ] && echo "RESULT: OK" || echo "RESULT: FAILED"
exit $rc
