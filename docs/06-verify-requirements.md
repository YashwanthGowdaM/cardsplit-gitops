# 06 · Verify every requirement (1-18)

Run these after chapter 05 shows everything `Synced / Healthy`. Replace `cardsplit-prod` with `cardsplit-dev`
to check dev. Outputs are examples; names/ages/IPs will differ.

## 1 · StorageClass and PVC

```bash
kubectl get storageclass
kubectl -n cardsplit-prod get pvc
kubectl get pv -o custom-columns=NAME:.metadata.name,SC:.spec.storageClassName,RECLAIM:.spec.persistentVolumeReclaimPolicy,SIZE:.spec.capacity.storage | head
```

**Expected output**

```
NAME         PROVISIONER       RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION
gp2          kubernetes.io/aws-ebs   Delete    WaitForFirstConsumer   false
gp3-delete (default)   ebs.csi.aws.com   Delete   WaitForFirstConsumer   true
gp3-retain   ebs.csi.aws.com   Retain          WaitForFirstConsumer   true

NAME              STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
data-database-0   Bound    pvc-5c1e...                                20Gi       RWO            gp3-retain     12m

NAME         SC           RECLAIM   SIZE
pvc-5c1e...  gp3-retain   Retain    20Gi
pvc-9a77...  gp3-delete   Delete    30Gi     (Prometheus)
```

*Explanation:* `volumeBindingMode: WaitForFirstConsumer` creates the EBS volume in the AZ where the database pod is
scheduled. `Retain` keeps the volume even if the PVC is deleted (data safety).

**Persistence test** - data survives a pod restart:

```bash
kubectl -n cardsplit-prod exec database-0 -c postgres -- psql -U cardsplit -d cardsplit -c "select count(*) from cards;"
kubectl -n cardsplit-prod delete pod database-0
kubectl -n cardsplit-prod wait --for=condition=ready pod/database-0 --timeout=180s
kubectl -n cardsplit-prod exec database-0 -c postgres -- psql -U cardsplit -d cardsplit -c "select count(*) from cards;"
```

**Expected output** (same count before and after)

```
 count
-------
     2
pod "database-0" deleted
pod/database-0 condition met
 count
-------
     2
```

## 2 · HPA and node autoscaling ("HNA")

```bash
kubectl -n cardsplit-prod get hpa
kubectl top pods -n cardsplit-prod
```

**Expected output**

```
NAME       REFERENCE             TARGETS                       MINPODS   MAXPODS   REPLICAS
backend    Deployment/backend    cpu: 4%/70%, memory: 38%/80%  2         6         2
frontend   Deployment/frontend   cpu: 1%/70%                   2         6         2

NAME                       CPU(cores)   MEMORY(bytes)
backend-6d8c7b9f5-abcde    3m           52Mi
frontend-7b5d9c8f6-fghij   1m           6Mi
database-0                 8m           118Mi
```

*Explanation:* if `TARGETS` shows `<unknown>`, metrics-server is not ready (chapter 08).

**Load test** (watch pods scale out, then back after ~5 min):

```bash
APP=http://$(kubectl -n cardsplit-prod get ingress frontend -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
kubectl run load --rm -it --restart=Never --image=busybox:1.36 -n cardsplit-prod --annotations=sidecar.istio.io/inject=false -- \
  sh -c 'for i in $(seq 1 8); do (while true; do wget -q -O- http://frontend/api/health >/dev/null; done) & done; sleep 240'
# in another terminal:
kubectl -n cardsplit-prod get hpa backend -w
```

**Expected output**

```
backend   Deployment/backend   cpu: 4%/70%    2   6   2
backend   Deployment/backend   cpu: 160%/70%  2   6   2
backend   Deployment/backend   cpu: 160%/70%  2   6   4
backend   Deployment/backend   cpu: 85%/70%   2   6   6
```

*HNA (node autoscaling):* if the extra pods do not fit, they go `Pending` and the Cluster Autoscaler adds a node:

```bash
kubectl -n kube-system logs -l app.kubernetes.io/instance=cluster-autoscaler --tail=5
kubectl get nodes -l workload=app
```

**Expected output**

```
I... scale_up.go:...] Final scale-up plan: [{eks-ng-app-... 2->3 (max: 6)}]
NAME   STATUS   ...
(3 nodes once scale-up completes; it removes the node ~10 minutes after the load stops)
```

## 3 · ConfigMap and Secrets

```bash
kubectl -n cardsplit-prod get configmap,secret
kubectl -n cardsplit-prod get sealedsecret
kubectl -n cardsplit-prod exec deploy/backend -c backend -- printenv DB_HOST DB_PORT PORT CORS_ORIGIN
```

**Expected output**

```
NAME                                DATA   AGE
configmap/backend-config-8k2h7m5d   5      20m
configmap/database-config-6t9c2g4f  1      20m
configmap/frontend-nginx-dc9b4h8k   1      20m
NAME                       TYPE     DATA   AGE
secret/cardsplit-secrets   Opaque   3      20m
NAME                AGE
cardsplit-secrets   20m
database
5432
5000
*
```

Passwords are never printed in this guide; to check that the backend has them without revealing values:
`kubectl -n cardsplit-prod exec deploy/backend -c backend -- sh -c 'test -n "$DB_PASSWORD" && echo DB_PASSWORD is set'`
→ `DB_PASSWORD is set`.

**Config change triggers a rollout:** edit `CORS_ORIGIN` in `apps/cardsplit/base/kustomization.yaml`, commit,
push → the ConfigMap name hash changes → `kubectl -n cardsplit-prod rollout status deploy/backend` shows a rolling update.

## 4 · Resource requests and limits

```bash
kubectl -n cardsplit-prod get pods -o custom-columns='POD:.metadata.name,CONTAINER:.spec.containers[*].name,CPU_REQ:.spec.containers[*].resources.requests.cpu,MEM_LIM:.spec.containers[*].resources.limits.memory'
kubectl -n cardsplit-prod describe resourcequota namespace-quota
kubectl -n cardsplit-prod get limitrange
```

**Expected output**

```
POD                        CONTAINER                          CPU_REQ        MEM_LIM
backend-...                backend,istio-proxy                100m,50m       384Mi,256Mi
frontend-...               frontend,istio-proxy               50m,50m        128Mi,256Mi
database-0                 postgres,postgres-exporter,istio-proxy   250m,20m,50m   1Gi,96Mi,256Mi

Name:            namespace-quota
Resource         Used    Hard
--------         ----    ----
limits.cpu       3200m   12
limits.memory    4224Mi  24Gi
pods             5       40
requests.cpu     720m    6
...
NAME             CREATED AT
default-limits   2026-10-28T07:01:12Z
```

*Explanation:* **requests** are what the scheduler reserves (and what HPA percentages are based on); **limits** are
the hard ceiling (CPU throttled, memory OOM-killed). The LimitRange gives sane defaults to any container that forgets them.

## 5 · RBAC

```bash
kubectl -n cardsplit-prod get role,rolebinding
kubectl get clusterrole platform-readonly
# impersonate a developer / viewer
kubectl auth can-i get pods   -n cardsplit-prod --as=jane --as-group=cardsplit-developers
kubectl auth can-i get secrets -n cardsplit-prod --as=jane --as-group=cardsplit-developers
kubectl auth can-i delete pods -n cardsplit-prod --as=bob  --as-group=cardsplit-viewers
kubectl auth can-i create pods/exec -n cardsplit-prod --as=jane --as-group=cardsplit-developers
# workloads have no API token
kubectl -n cardsplit-prod get pod -l app=backend -o jsonpath='{.items[0].spec.automountServiceAccountToken}'; echo
```

**Expected output**

```
NAME                                         AGE
role.rbac.authorization.k8s.io/cardsplit-developer   20m
role.rbac.authorization.k8s.io/cardsplit-viewer      20m
NAME                                                  ROLE                    AGE
rolebinding.rbac.authorization.k8s.io/cardsplit-developers   Role/cardsplit-developer   20m
rolebinding.rbac.authorization.k8s.io/cardsplit-viewers      Role/cardsplit-viewer      20m
NAME                CREATED AT
platform-readonly   2026-10-28T06:58:00Z
yes
no
no
yes
false
```

ArgoCD RBAC: in the UI / CLI, `argocd account can-i sync applications 'cardsplit/*'` (as a user in group
`cardsplit-deployers`) → `yes`; deleting is not allowed.

## 6 · Fluent Bit

```bash
kubectl -n logging get ds,pods -l app.kubernetes.io/name=fluent-bit
kubectl -n logging logs ds/fluent-bit --tail=5
```

**Expected output**

```
NAME                        DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR
daemonset.apps/fluent-bit   5         5         5       5            5           <none>
NAME               READY   STATUS    RESTARTS   AGE
pod/fluent-bit-... 1/1     Running   0          15m     (one per node - 5 nodes, including the tainted data node)
[ info] [output:splunk:splunk.0] worker #0 started
[ info] [input:tail:tail.0] inotify_fs_add(): inode=... watching /var/log/containers/backend-...log
```

*Explanation:* `DESIRED = number of nodes` proves the toleration works (requirement 16) - without it the data node
would be missing from the count.

## 7 · Splunk

```bash
kubectl -n logging get statefulset,pvc
kubectl -n logging get svc splunk-web
```

**Expected output**

```
NAME                      READY   AGE
statefulset.apps/splunk   1/1     18m
NAME                       STATUS   VOLUME     CAPACITY   STORAGECLASS
persistentvolumeclaim/var-splunk-0   Bound   pvc-...   50Gi   gp3-delete
NAME         TYPE           EXTERNAL-IP                          PORT(S)
splunk-web   LoadBalancer   k8s-logging-splunkwe-....elb...      8000:3xxxx/TCP
```

Open `http://<splunk-nlb>:8000`, log in as `admin`, then **Search & Reporting** and run:

```
index=main sourcetype=_json kubernetes.namespace_name="cardsplit-prod" | stats count by kubernetes.container_name
```

**Expected result:** a table with rows such as `backend`, `frontend`, `postgres`, `istio-proxy` and counts > 0.
Generate traffic by browsing the app if the table is empty. Also try
`index=main kubernetes.container_name=backend "GET /api/cards"`.

## 8 · ArgoCD

```bash
kubectl -n argocd get applications
argocd app get cardsplit-prod --grpc-web | head -20
```

**Expected output**

```
Name:               argocd/cardsplit-prod
Project:            cardsplit
Server:             https://kubernetes.default.svc
Namespace:          cardsplit-prod
URL:                https://<argocd-nlb>/applications/cardsplit-prod
Repo:               https://github.com/<you>/cardsplit-gitops.git
Target:             main
Path:               apps/cardsplit/overlays/prod
SyncWindow:         Sync Allowed
Sync Policy:        Automated (Prune)
Sync Status:        Synced to main (5d6e7f8)
Health Status:      Healthy
```

In the UI the `cardsplit-prod` tile shows the resource tree (Namespace → Deployments → ReplicaSets → Pods, StatefulSet,
Ingress, HPA ...).

**Self-heal test** - delete something ArgoCD owns; it is recreated from Git within about a minute:

```bash
kubectl -n cardsplit-prod delete svc backend
sleep 70
kubectl -n cardsplit-prod get svc backend
```

**Expected output**

```
service "backend" deleted
NAME      TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
backend   ClusterIP   10.100.55.201   <none>        5000/TCP   58s     <- re-created by ArgoCD
```

(The Deployments' `replicas` field is intentionally ignored by ArgoCD - the HPA owns it.)

## 9 · Prometheus and Grafana

```bash
kubectl -n monitoring get pods
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090 &
curl -s 'http://localhost:9090/api/v1/query?query=sum(istio_requests_total)' | head -c 300; echo
curl -s http://localhost:9090/api/v1/rules | grep -o 'CardSplit[A-Za-z0-9]*' | sort -u
kill %1
```

**Expected output**

```
NAME                                                     READY   STATUS
alertmanager-kube-prometheus-stack-alertmanager-0        2/2     Running
kube-prometheus-stack-grafana-...                        3/3     Running
kube-prometheus-stack-operator-...                       1/1     Running
kube-state-metrics-...                                   1/1     Running
prometheus-kube-prometheus-stack-prometheus-0            2/2     Running
prometheus-node-exporter-... (x5)                        1/1     Running
{"status":"success","data":{"resultType":"vector","result":[{"metric":{},"value":[1761630000,"1234"]}]}}
CardSplitBackendDown
CardSplitBackendHigh5xxRate
CardSplitBackendHighLatencyP95
CardSplitDatabaseDown
CardSplitFrontendDown
CardSplitHpaAtMaxReplicas
CardSplitPodCrashLooping
CardSplitVolumeAlmostFull
```

Grafana (`http://<grafana-nlb>`): **Dashboards → CardSplit Overview** (8 panels: request rate, 5xx, p50/p95/p99,
replicas, CPU, memory, Postgres connections, volume usage) and the folder **Istio** (Mesh, Service, Workload,
Control Plane). **Explore → Jaeger** is also pre-configured. Prometheus targets: Status → Targets should list
`podMonitor/istio-system/envoy-stats` and `serviceMonitor/istio-system/istiod` as UP.

## 10 · Kiali

```bash
kubectl -n istio-system get pods -l app.kubernetes.io/name=kiali
kubectl -n istio-system create token kiali --duration=8h
```

**Expected output**

```
NAME                     READY   STATUS    RESTARTS   AGE
kiali-6c9d7f5b8d-xxxxx   1/1     Running   0          15m
eyJhbGciOiJSUzI1NiIsImtpZCI6...        <- paste into the Kiali login page
```

Open `http://<kiali-nlb>:20001`, paste the token. **Graph** → namespace `cardsplit-prod` → *Display: Traffic
animation, Security*. **Expected:** `frontend → backend → database` with padlock icons (mTLS) and green edges
after you generate traffic by using the app. **Istio Config** shows no validation errors (all green ticks).

## 11 · Deployment strategy

```bash
kubectl -n cardsplit-prod get deploy backend -o jsonpath='{.spec.strategy}{"\n"}{.spec.minReadySeconds}{"\n"}'
kubectl -n cardsplit-prod get sts database -o jsonpath='{.spec.updateStrategy}{"\n"}'
kubectl -n cardsplit-prod get pdb
```

**Expected output**

```
{"rollingUpdate":{"maxSurge":1,"maxUnavailable":0},"type":"RollingUpdate"}
10
{"rollingUpdate":{"partition":0},"type":"RollingUpdate"}
NAME       MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS
backend    N/A             1                 1
frontend   N/A             1                 1
```

*Explanation:* **RollingUpdate with `maxUnavailable: 0`** starts a new pod first and only removes an old one once the
new one is Ready (readiness probe) - zero downtime. `minReadySeconds` makes sure the new pod is stable;
the `preStop` sleep lets the ALB/mesh stop sending traffic before the pod is terminated; PDBs protect against
node drains. **Live demo:** watch `kubectl -n cardsplit-prod get pods -w` while chapter 07's pipeline ships a new tag.
Rollback = `git revert` the image-tag commit (see chapter 07).

## 12 + 13 · Internet exposure only through load balancers; frontend through the Ingress

```bash
kubectl get ingress -A
kubectl get svc -A --field-selector spec.type=LoadBalancer
kubectl get svc -A --field-selector spec.type=NodePort
```

**Expected output**

```
NAMESPACE        NAME       CLASS   HOSTS   ADDRESS                                         PORTS   AGE
cardsplit-dev    frontend   alb     *       k8s-cardspli-frontend-...elb.ap-south-1.amazonaws.com   80   30m
cardsplit-prod   frontend   alb     *       k8s-cardspli-frontend-...elb.ap-south-1.amazonaws.com   80   30m

NAMESPACE       NAME                            TYPE           EXTERNAL-IP
argocd          argocd-server                   LoadBalancer   k8s-argocd-....elb...
istio-system    kiali                           LoadBalancer   k8s-istiosys-....elb...
logging         splunk-web                      LoadBalancer   k8s-logging-....elb...
monitoring      kube-prometheus-stack-grafana   LoadBalancer   k8s-monitori-....elb...
observability   jaeger-query                    LoadBalancer   k8s-observab-....elb...

No resources found
```

```bash
APP=$(kubectl -n cardsplit-prod get ingress frontend -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s -o /dev/null -w "%{http_code}\n" http://$APP/
curl -s http://$APP/api/health
```

**Expected output**

```
200
{"status":"ok","service":"cardsplit-backend","database":"connected","uptimeSeconds":812}
```

*Explanation:* browser → ALB → frontend pod (nginx) → `/api` proxied to the backend Service inside the cluster.
**No NodePorts**, and the backend/database/Prometheus have no public address at all (Prometheus is deliberately
`ClusterIP`; see chapter 08 if you want it public).

## 14 · Pod affinity and anti-affinity

```bash
kubectl -n cardsplit-prod get pods -l 'app in (frontend,backend,database)' \
  -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName,APP:.metadata.labels.app
```

**Expected output** (replicas of the same app on **different nodes**; database alone on its node)

```
POD                  NODE                                            APP
backend-xxxxx-aaaaa  ip-192-168-12-4.ap-south-1.compute.internal      backend
backend-xxxxx-bbbbb  ip-192-168-45-9.ap-south-1.compute.internal      backend
frontend-yyyyy-aaaaa ip-192-168-12-4.ap-south-1.compute.internal      frontend
frontend-yyyyy-bbbbb ip-192-168-45-9.ap-south-1.compute.internal      frontend
database-0           ip-192-168-18-77.ap-south-1.compute.internal     database
```

*Explanation:* **pod anti-affinity** (`kubernetes.io/hostname`) spreads same-app replicas across nodes;
**pod affinity** (zone) pulls backend toward the database's AZ and frontend toward the backend's AZ; the database has a
**required anti-affinity** against frontend/backend. Show the rules:
`kubectl -n cardsplit-prod get deploy backend -o jsonpath='{.spec.template.spec.affinity}' | python3 -m json.tool`.

## 15 · Node affinity and node anti-affinity

```bash
kubectl -n cardsplit-prod get deploy backend  -o jsonpath='{.spec.template.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions}{"\n"}'
kubectl -n cardsplit-prod get deploy frontend -o jsonpath='{.spec.template.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions}{"\n"}'
kubectl -n cardsplit-prod get sts    database -o jsonpath='{.spec.template.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions}{"\n"}'
```

**Expected output**

```
[{"key":"workload","operator":"In","values":["app"]}]                  <- backend: node AFFINITY
[{"key":"workload","operator":"NotIn","values":["data","platform"]}]   <- frontend: node ANTI-affinity
[{"key":"workload","operator":"In","values":["data"]}]                 <- database: node AFFINITY (data nodes)
```

**Negative test** - prove the rule is enforced:

```bash
kubectl -n cardsplit-dev patch deploy frontend --type merge -p '{"spec":{"template":{"spec":{"nodeSelector":{"workload":"data"}}}}}'
kubectl -n cardsplit-dev get pods -l app=frontend
kubectl -n cardsplit-dev describe pod -l app=frontend | grep -A3 Events | tail -4
```

**Expected output** (a new pod stays Pending because "NotIn data" + nodeSelector data can never match)

```
frontend-...   0/2   Pending   0   10s
Warning  FailedScheduling  ...  0/5 nodes are available: 1 node(s) didn't match Pod's node affinity/selector, ...
```

Undo by letting ArgoCD self-heal (`argocd app sync cardsplit-dev --grpc-web`) or
`kubectl -n cardsplit-dev patch deploy frontend --type json -p '[{"op":"remove","path":"/spec/template/spec/nodeSelector"}]'`.

## 16 · Taints and tolerations

```bash
kubectl describe node -l workload=data | grep -A1 Taints
kubectl -n cardsplit-prod get sts database -o jsonpath='{.spec.template.spec.tolerations}{"\n"}'
kubectl -n cardsplit-prod get pods -o wide | grep -E 'NAME|database'
```

**Expected output**

```
Taints:             dedicated=data:NoSchedule
[{"effect":"NoSchedule","key":"dedicated","operator":"Equal","value":"data"}]
database-0   3/3   Running   0   25m   192.168.18.90   ip-192-168-18-77.ap-south-1.compute.internal
```

**Negative test** - a pod without the toleration cannot land there:

```bash
kubectl run taint-test --image=busybox:1.36 --restart=Never -n default \
  --overrides='{"spec":{"nodeSelector":{"workload":"data"},"containers":[{"name":"t","image":"busybox:1.36","command":["sleep","60"]}]}}'
kubectl describe pod taint-test -n default | grep -A2 Events
kubectl delete pod taint-test -n default
```

**Expected output**

```
Warning  FailedScheduling  ...  0/5 nodes are available: 1 node(s) had untolerated taint {dedicated: data}, ...
pod "taint-test" deleted
```

## 17 · Probes

```bash
kubectl -n cardsplit-prod describe pod -l app=backend | grep -E 'Liveness|Readiness|Startup'
kubectl -n cardsplit-prod get pods
```

**Expected output**

```
    Liveness:   http-get http://:15020/app-health/backend/livez delay=0s timeout=3s period=20s #success=1 #failure=3
    Readiness:  http-get http://:15020/app-health/backend/readyz delay=0s timeout=3s period=10s #success=1 #failure=3
    Startup:    http-get http://:15020/app-health/backend/startupz delay=0s timeout=3s period=5s #success=1 #failure=30
NAME                      READY   STATUS    RESTARTS   AGE
backend-...               2/2     Running   0          30m
```

*Explanation:* Istio rewrites HTTP probes to its agent (port 15020) so they work under STRICT mTLS; the original
paths (`/api/health`, `/`) are still what is checked. **Readiness demo** - stop the database and watch the backend go
unready (but not restart):

```bash
kubectl -n cardsplit-dev scale sts database --replicas=0
sleep 45; kubectl -n cardsplit-dev get pods -l app=backend
kubectl -n cardsplit-dev scale sts database --replicas=1
```

**Expected output**

```
NAME            READY   STATUS    RESTARTS   AGE
backend-...     1/2     Running   0          9m      <- app container NotReady (readiness fails), RESTARTS stays 0
```

(ArgoCD may scale the StatefulSet back by itself - that is self-heal doing its job.)

## 18 · Jaeger

1. Use the app (open dashboard, click around, add a card).
2. Open `http://<jaeger-nlb>:16686` → **Service** dropdown → choose `frontend.cardsplit-prod` (or `backend...`) →
   **Find Traces**.

```bash
kubectl -n observability get pods,svc
```

**Expected output**

```
NAME                          READY   STATUS    RESTARTS   AGE
pod/jaeger-xxxxxxxxxx-xxxxx   1/1     Running   0          25m
NAME                       TYPE           CLUSTER-IP      EXTERNAL-IP        PORT(S)
service/jaeger-collector   ClusterIP      10.100.x.x      <none>             4317/TCP,4318/TCP
service/jaeger-query       LoadBalancer   10.100.y.y      k8s-observab-...   16686:3xxxx/TCP
```

**Expected UI result:** a list of traces; opening one shows spans such as
`frontend.cardsplit-prod → backend.cardsplit-prod:5000/api/cards` with durations. Kiali's *Traces* tab and Grafana's
Jaeger data source show the same traces.

> Honest limit: spans come from the Envoy sidecars, so you see **hop-level** traces (frontend → backend). The
> backend → PostgreSQL call is plain TCP, and code-level spans inside Node need OpenTelemetry instrumentation of the
> backend (chapter 08, "Next steps").
