# 05 · Install ArgoCD and let it deploy everything

Implements: **ArgoCD (8)**, **LB exposure (12)**, **Ingress for the frontend (13)**, and starts all platform pieces
(6, 7, 9, 10, 18) plus the app.

## 5.1 (Private repo only) give ArgoCD read access

```bash
kubectl create namespace argocd
cp bootstrap/repo-credentials.example.yaml /tmp/repo-creds.yaml      # edit username + token in /tmp copy
kubectl apply -f /tmp/repo-creds.yaml && rm /tmp/repo-creds.yaml
```

**Expected output**

```
namespace/argocd created
secret/cardsplit-gitops-repo created
```

## 5.2 Install ArgoCD with Helm (one-time bootstrap)

```bash
helm repo add argo https://argoproj.github.io/argo-helm && helm repo update
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace -f bootstrap/argocd-values.yaml --wait
```

**Expected output**

```
Release "argocd" does not exist. Installing it now.
NAME: argocd
NAMESPACE: argocd
STATUS: deployed
...
```

```bash
kubectl -n argocd get pods
```

**Expected output**

```
NAME                                                READY   STATUS    RESTARTS   AGE
argocd-application-controller-0                     1/1     Running   0          90s
argocd-applicationset-controller-xxxxxxxxxx-xxxxx   1/1     Running   0          90s
argocd-notifications-controller-xxxxxxxxxx-xxxxx    1/1     Running   0          90s
argocd-redis-xxxxxxxxxx-xxxxx                       1/1     Running   0          90s
argocd-repo-server-xxxxxxxxxx-xxxxx                 1/1     Running   0          90s
argocd-server-xxxxxxxxxx-xxxxx                      1/1     Running   0          90s
```

> The chart is installed with default (floating) version; to make it reproducible add `--version <x.y.z>` from
> `helm search repo argo/argo-cd`.

## 5.3 Open the ArgoCD UI (internet-facing NLB)

```bash
kubectl -n argocd get svc argocd-server
```

**Expected output** (the NLB takes 2-3 minutes to get a hostname)

```
NAME            TYPE           CLUSTER-IP      EXTERNAL-IP                                                          PORT(S)                      AGE
argocd-server   LoadBalancer   10.100.12.34    k8s-argocd-argocdse-0a1b2c3d4e-5f6g7h8i9j.elb.ap-south-1.amazonaws.com   80:31022/TCP,443:30977/TCP   2m
```

Initial admin password and login:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
ARGO=$(kubectl -n argocd get svc argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
argocd login $ARGO --username admin --insecure --grpc-web
```

**Expected output**

```
Xk3fP9...                                   <- the password
Password: ********
'admin:login' logged in successfully
Context '<nlb-hostname>' updated
```

Browse to `https://<nlb-hostname>` (accept the self-signed certificate warning), user `admin`.
Then **change the password** (User Info → Update Password) and delete the initial secret:
`kubectl -n argocd delete secret argocd-initial-admin-secret`.

## 5.4 Hand over to GitOps: apply the root application

```bash
kubectl apply -f bootstrap/root-app.yaml
```

**Expected output**

```
application.argoproj.io/root created
```

From now on **Git is the source of truth**. The root app creates the two AppProjects and 16 Applications; ArgoCD
processes them in *sync-wave* order and waits for each wave to be healthy:

| Wave | Applications |
|---|---|
| -10 | AppProjects `platform`, `cardsplit` |
| -3 | sealed-secrets (adopts the release from 3.1) |
| -2 | metrics-server, aws-load-balancer-controller, cluster-autoscaler |
| -1 | platform-base (namespaces, StorageClasses, RBAC, secrets) |
| 1-3 | istio-base → istiod → istio-config (mesh, tracing, mTLS default) |
| 4-5 | kube-prometheus-stack → monitoring-extras (Istio monitors, alerts, dashboard) |
| 6 | jaeger, splunk |
| 7 | fluent-bit, kiali |
| 8 | cardsplit-dev, cardsplit-prod |

## 5.5 Watch it converge (10-20 minutes; Splunk is the slowest)

```bash
watch -n 10 'kubectl -n argocd get applications'
```

**Expected final output**

```
NAME                           SYNC STATUS   HEALTH STATUS
aws-load-balancer-controller   Synced        Healthy
cardsplit-dev                  Synced        Healthy
cardsplit-prod                 Synced        Healthy
cluster-autoscaler             Synced        Healthy
fluent-bit                     Synced        Healthy
istio-base                     Synced        Healthy
istio-config                   Synced        Healthy
istiod                         Synced        Healthy
jaeger                         Synced        Healthy
kiali                          Synced        Healthy
kube-prometheus-stack          Synced        Healthy
metrics-server                 Synced        Healthy
monitoring-extras              Synced        Healthy
platform-base                  Synced        Healthy
root                           Synced        Healthy
sealed-secrets                 Synced        Healthy
splunk                         Synced        Healthy
```

If something is `OutOfSync`/`Degraded` see chapter 08 → *Troubleshooting*.

## 5.6 Find all the public addresses

```bash
echo "APP (prod):  http://$(kubectl -n cardsplit-prod get ingress frontend -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
echo "APP (dev):   http://$(kubectl -n cardsplit-dev  get ingress frontend -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
for x in argocd/argocd-server monitoring/kube-prometheus-stack-grafana istio-system/kiali observability/jaeger-query logging/splunk-web; do
  ns=${x%%/*}; svc=${x##*/}
  echo "$svc: $(kubectl -n $ns get svc $svc -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
done
```

**Expected output**

```
APP (prod):  http://k8s-cardspli-frontend-1a2b3c4d5e-123456789.ap-south-1.elb.amazonaws.com
APP (dev):   http://k8s-cardspli-frontend-9z8y7x6w5v-987654321.ap-south-1.elb.amazonaws.com
argocd-server: k8s-argocd-argocdse-....elb.ap-south-1.amazonaws.com
kube-prometheus-stack-grafana: k8s-monitori-kubeprom-....elb.ap-south-1.amazonaws.com
kiali: k8s-istiosys-kiali-....elb.ap-south-1.amazonaws.com
jaeger-query: k8s-observab-jaegerqu-....elb.ap-south-1.amazonaws.com
splunk-web: k8s-logging-splunkwe-....elb.ap-south-1.amazonaws.com
```

| UI | URL | Login |
|---|---|---|
| CardSplit | `http://<alb>` | admin password you sealed (to unlock editing) |
| ArgoCD | `https://<nlb>` | admin / (changed) |
| Grafana | `http://<nlb>` | admin / password from 3.2 |
| Kiali | `http://<nlb>:20001` | token: `kubectl -n istio-system create token kiali` |
| Jaeger | `http://<nlb>:16686` | none (restrict with ADMIN_CIDR!) |
| Splunk | `http://<nlb>:8000` | admin / password from 3.2 |

Open the CardSplit URL: you should see the app. The page header's status badge should show the API as healthy.

## 5.7 Make deployments instant (optional webhook)

ArgoCD already polls Git every 60 s. For instant sync add a GitHub webhook on the **GitOps repo**:
Payload URL `https://<argocd-nlb>/api/webhook`, content type `application/json`, event *push*
(self-signed certificate: untick *Enable SSL verification*, or put a real certificate on the NLB).
