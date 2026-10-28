# 03 · Secrets (Sealed Secrets) and the first push of this repo

Implements: **ConfigMap & Secrets (3)**.

*Why not plain Secrets in Git?* A Kubernetes `Secret` is only base64 - anyone who can read the repo can read the
password. **Sealed Secrets** encrypts each secret with a key that exists only inside your cluster; the encrypted
file (`SealedSecret`) is safe to commit, and the controller turns it back into a normal `Secret` in the cluster.

How config reaches the pods:

| What | Kind | Defined in | Consumed by |
|---|---|---|---|
| PORT, DB_HOST, DB_PORT, DB_NAME, CORS_ORIGIN | ConfigMap `backend-config` | `base/kustomization.yaml` (generator) | backend `envFrom` |
| POSTGRES_DB | ConfigMap `database-config` | same | database + exporter |
| nginx config | ConfigMap `frontend-nginx` | `base/nginx.conf.template` | frontend volume mount |
| DB_USER, DB_PASSWORD, ADMIN_PASSWORD | Secret `cardsplit-secrets` | `overlays/*/secret.yaml` | backend, database, exporter |
| Grafana admin | Secret `grafana-admin` | `platform/base/secrets/` | Grafana |
| Splunk password + HEC token | Secret `splunk-secrets` | `platform/base/secrets/` | Splunk, Fluent Bit |

ConfigMaps are generated **with a content hash in the name** (`backend-config-7k2f9d`). Change a value → new name →
Deployment spec changes → automatic rolling restart.

## 3.1 Install the Sealed Secrets controller (once, by hand)

ArgoCD will adopt this same release later (chapter 05). We install it first so we can encrypt before anything is
committed.

```bash
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm repo update
helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
  -n kube-system -f platform/sealed-secrets/values.yaml
kubectl -n kube-system rollout status deploy/sealed-secrets-controller
```

**Expected output**

```
Release "sealed-secrets" does not exist. Installing it now.
NAME: sealed-secrets
STATUS: deployed
...
deployment "sealed-secrets-controller" successfully rolled out
```

## 3.2 Encrypt the passwords

```bash
./scripts/seal-secrets.sh
```

Type the five passwords when prompted (input is hidden).

**Expected output**

```
CardSplit ADMIN password (unlocks add/edit/delete in the UI):
PostgreSQL password (dev):
PostgreSQL password (prod):
Grafana admin password:
Splunk admin password (min 8 chars):
sealed: apps/cardsplit/overlays/dev/secret.yaml
sealed: apps/cardsplit/overlays/prod/secret.yaml
sealed: platform/base/secrets/grafana-admin.yaml
sealed: platform/base/secrets/splunk-secrets.yaml
Done. Review 'git diff', then commit + push.
```

Check that the files are now encrypted:

```bash
head -12 apps/cardsplit/overlays/prod/secret.yaml
```

**Expected output**

```yaml
---
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: cardsplit-secrets
  namespace: cardsplit-prod
spec:
  encryptedData:
    ADMIN_PASSWORD: AgBy3i4OJSWK+PiTySYZZA9rO43cGDEq...
    DB_PASSWORD: AgAKAoiQm7xFtD0GJ...
    DB_USER: AgCtr8...
```

> **Back up the controller key** (otherwise a rebuilt cluster cannot decrypt your files):
> `kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > sealed-secrets-key-backup.yaml`
> and store the file somewhere safe **outside Git**.

## 3.3 Validate, commit, push

```bash
make validate-strict
```

**Expected output**

```
== 1. YAML syntax
  checked, failures: 0
== 2. kustomize build (if kustomize is installed)
  OK   apps/cardsplit/overlays/dev (3x objects)
  OK   apps/cardsplit/overlays/prod (3x objects)
  OK   platform/base (..)
  ...
== 4. Secrets / placeholders
  none (good)
  all tokens replaced
RESULT: OK
```

```bash
git add -A
git commit -m "feat: initial CardSplit GitOps repository"
git remote add origin https://github.com/<you>/cardsplit-gitops.git
git push -u origin main
```

**Expected output**

```
[main (root-commit) 3f1c2ab] feat: initial CardSplit GitOps repository
 120 files changed, ...
Enumerating objects: ...
To https://github.com/<you>/cardsplit-gitops.git
 * [new branch]      main -> main
```

(When asked for a password, paste the fine-grained token from chapter 01.)
