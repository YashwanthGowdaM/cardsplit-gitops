# 07 · End-to-end CI/CD test: code change → Jenkins → ECR → Git → ArgoCD → pods

## 7.1 Make a visible change in the app repo

```bash
cd ../CreditCardBillSplitter
sed -i 's|CardSplit API is running.|CardSplit API is running (v2).|' backend/src/server.js
git commit -am "feat: bump root message" && git push
```

**Expected output**

```
[main 4e5f6a7] feat: bump root message
 1 file changed, 1 insertion(+), 1 deletion(-)
```

## 7.2 Jenkins builds automatically (webhook)

Open the `cardsplit-app` job → `main`.

**Expected output**

```
Started by GitHub push by <you>
...
Image tag: 2-4e5f6a7
2-4e5f6a7: digest: sha256:... size: 1783          (frontend, backend, database)
[main c0ffee1] ci(dev): deploy cardsplit 2-4e5f6a7
Finished: SUCCESS
```

## 7.3 ArgoCD detects the commit and rolls out DEV

```bash
argocd app get cardsplit-dev --grpc-web | grep -E 'Sync Status|Health'
kubectl -n cardsplit-dev rollout status deploy/backend
kubectl -n cardsplit-dev get deploy backend -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

**Expected output** (within ~1 minute; instant with the webhook)

```
Sync Status:        Synced to main (c0ffee1)
Health Status:      Healthy
Waiting for deployment "backend" rollout to finish: 1 old replicas are pending termination...
deployment "backend" successfully rolled out
123456789012.dkr.ecr.ap-south-1.amazonaws.com/cardsplit/backend:2-4e5f6a7
```

Note the **zero-downtime** behaviour: `kubectl -n cardsplit-dev get pods -w` shows the new pod becoming Ready
before the old one terminates. Check the API:

```bash
curl -s http://$(kubectl -n cardsplit-dev get ingress frontend -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')/api/health
```

**Expected output**

```
{"status":"ok","service":"cardsplit-backend","database":"connected","uptimeSeconds":14}
```

## 7.4 Promote to PROD

Run the Jenkins job `cardsplit-promote-prod` → approve.

**Expected output**

```
[main 7a8b9c0] release(prod): promote dev image tags (build 2)
```

```bash
kubectl -n cardsplit-prod rollout status deploy/backend && kubectl -n cardsplit-prod get deploy backend -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

**Expected output**

```
deployment "backend" successfully rolled out
123456789012.dkr.ecr.ap-south-1.amazonaws.com/cardsplit/backend:2-4e5f6a7
```

## 7.5 Roll back (Git is the history)

```bash
cd ../cardsplit-gitops && git pull
git revert --no-edit 7a8b9c0          # the promote commit
git push
```

**Expected output**

```
[main 1d2e3f4] Revert "release(prod): promote dev image tags (build 2)"
```

ArgoCD syncs `cardsplit-prod` back to `1-3fa9c1e` within a minute (`argocd app history cardsplit-prod --grpc-web`
lists both revisions). Never roll back with `kubectl rollout undo` on ArgoCD-managed apps - self-heal would undo it.

## 7.6 Prove "any repo change triggers ArgoCD"

Change anything in this repo (for example `maxReplicas` in `apps/cardsplit/base/hpa.yaml`), commit and push:

```bash
sed -i '0,/maxReplicas: 6/s//maxReplicas: 8/' apps/cardsplit/base/hpa.yaml
git commit -am "tune: backend max replicas 8" && git push
sleep 70
kubectl -n cardsplit-prod get hpa backend
```

**Expected output**

```
NAME      REFERENCE            TARGETS            MINPODS   MAXPODS   REPLICAS
backend   Deployment/backend   cpu: 4%/70% ...    2         8         2
```
