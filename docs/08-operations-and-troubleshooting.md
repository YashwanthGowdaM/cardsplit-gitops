# 08 · Operations, troubleshooting, design notes and cleanup

## 8.1 Troubleshooting cheat-sheet

| Symptom | Check | Usual cause / fix |
|---|---|---|
| App `OutOfSync` with *"CustomResourceDefinition ... not found"* | `argocd app get <app>` | A CRD wave has not finished yet. Wait, or `argocd app sync <app> --grpc-web`. Apps already have `SkipDryRunOnMissingResource`. |
| Pods `ImagePullBackOff` with tag `0.0.0` | `kubectl describe pod` | Jenkins has not pushed/committed real tags yet (chapter 04, 4.6-4.7). |
| Pods `ImagePullBackOff`, `not found` | tag in overlay vs `aws ecr describe-images` | Typo/old tag; node role needs ECR read (eksctl adds it by default). |
| Pods `CreateContainerConfigError` / secret not found | `kubectl -n <ns> get sealedsecret,secret` ; `kubectl -n kube-system logs deploy/sealed-secrets-controller` | SealedSecret sealed for another cluster/namespace name, or placeholders still in Git. Re-run `scripts/seal-secrets.sh`. |
| `database-0` Pending | `kubectl describe pod database-0` | No node labelled `workload=data`, taint mismatch, or the data node's AZ differs from an existing volume (volumes are AZ-bound). |
| HPA shows `<unknown>` | `kubectl -n kube-system get pods -l app.kubernetes.io/name=metrics-server` | metrics-server not ready; check `kubectl top nodes`. |
| Ingress has no ADDRESS | `kubectl -n kube-system logs -l app.kubernetes.io/name=aws-load-balancer-controller` | IRSA service account missing (chapter 02.4) or subnets lack the `kubernetes.io/role/elb` tag (eksctl sets it). |
| NLB hostname never appears | same logs | same; also AWS service quota for load balancers. |
| Frontend 502 on `/api` | `kubectl -n <ns> logs deploy/frontend -c frontend` | `BACKEND_HOST` wrong, backend not Ready, or AuthorizationPolicy mismatch (namespace in the principal). |
| Backend 503 `RBAC: access denied` in Envoy logs | `kubectl -n <ns> get authorizationpolicy -o yaml` | Principal must be `cluster.local/ns/<ns>/sa/frontend`. |
| Backend cannot reach DB under STRICT mTLS | `istioctl x describe pod <backend-pod>` | Missing sidecar (namespace label `istio-injection=enabled`, restart pods). |
| No Splunk data | `kubectl -n logging logs ds/fluent-bit` | HEC token mismatch (re-seal), Splunk still starting (first start 3-5 min), TLS settings. |
| Grafana Istio dashboards empty | Prometheus → Status → Targets | `envoy-stats` PodMonitor not UP; pods need sidecars + traffic. |
| Kiali "unreachable Prometheus" | Kiali pod logs | URL in `platform/kiali/values.yaml` must match the Prometheus service name. |
| Jaeger has no services | `kubectl -n istio-system get telemetry` | Telemetry resource missing or `jaeger-otel` provider not in `istiod-values.yaml`; restart workloads after Istio changes. |

Useful commands: `argocd app diff <app> --grpc-web`, `argocd app sync <app> --grpc-web`,
`kubectl -n argocd logs deploy/argocd-repo-server`, `kubectl get events -A --sort-by=.lastTimestamp | tail -20`.

## 8.2 Day-2 tasks

* **Pin chart versions** (reproducible deploys): `make pin` (needs `helm`, `yq`), review `git diff argocd/apps`, commit.
  Charts ship with floating majors (`70.*`, `1.31.*`, ...) so the first install gets a current compatible release.
* **Rotate a password:** `make seal`, commit, push, then `kubectl -n <ns> rollout restart deploy/backend`
  (changing a Secret does not roll pods by itself; consider the *Reloader* controller). Changing the **database**
  password only works for a *new* database - the user/password inside Postgres were fixed on first start.
* **Expand a volume:** edit the size in the overlay patch; for StatefulSet PVCs, patch the live PVC
  (`kubectl patch pvc data-database-0 -p '{"spec":{"resources":{"requests":{"storage":"30Gi"}}}}'`) because
  `volumeClaimTemplates` are immutable. The StorageClass allows expansion.
* **Upgrade EKS / nodes:** `eksctl upgrade cluster`, then `eksctl upgrade nodegroup` per group. PDBs keep the app up.
  The data node group is single-AZ and has a single database replica → expect a short DB outage during its upgrade.
* **Alert delivery:** add a Slack/e-mail receiver under `alertmanager.config` in
  `platform/monitoring/kube-prometheus-stack-values.yaml` (keep the webhook URL in a SealedSecret).
* **Prod manual approval in ArgoCD:** remove `automated:` from `argocd/apps/cardsplit-prod.yaml`; promotion
  commits then show as *OutOfSync* until someone clicks *Sync*.
* **Backups:** add a CronJob running `pg_dump` to S3 (not included: it needs IRSA + a mesh-aware Job); EBS snapshots
  via AWS Backup on the `gp3-retain` volumes are the quickest option.

## 8.3 Design decisions and known limits (please read)

* **"HNA"** was interpreted as **Horizontal Node Autoscaler = Cluster Autoscaler**. If you meant something else
  (VPA, Karpenter), tell me and the file is easy to swap.
* **Public admin UIs.** As requested, ArgoCD, Grafana, Kiali, Jaeger and Splunk are on internet-facing NLBs over plain
  HTTP (ArgoCD is HTTPS with a self-signed cert). Passwords and the Kiali token travel unencrypted. Mitigations built
  in: `ADMIN_CIDR` source-range restriction. **Jaeger has no login at all** - keep `ADMIN_CIDR` tight. For HTTPS add an ACM
  certificate + the commented `aws-load-balancer-ssl-*` annotations (needs a domain). **Prometheus** is kept private
  on purpose (no auth); change `prometheus.service.type` to `LoadBalancer` if you must.
* **Splunk** runs as a single instance with the trial/free licence (500 MB/day after 60 days). It needs ≥ 4 GiB RAM.
  Production Splunk uses the Splunk Operator/indexer clusters.
* **Jaeger** uses in-memory storage (traces vanish on restart) and is traces-at-the-mesh only. For persistence use
  OpenSearch/Elasticsearch/Cassandra; for deeper traces add OpenTelemetry to the Node backend.
* **Single database replica**, single AZ, EBS volume. This is a lab-grade HA story (fast pod rescheduling + retained
  volume + backups), not a replicated Postgres cluster. For real HA use CloudNativePG/Patroni or Amazon RDS.
* **Secrets:** Sealed Secrets keeps ciphertext in Git. Changing a Secret value does not restart pods automatically.
  An alternative for AWS-native setups is External Secrets Operator + AWS Secrets Manager.
* **Frontend root container:** the stock nginx image starts as root (to bind port 80); it runs with all capabilities
  dropped except the four it needs. Switching the app Dockerfile to `nginxinc/nginx-unprivileged` (port 8080) would
  allow `runAsNonRoot` - a small app-repo change.
* **nginx resolver:** the Kubernetes nginx config is provided by a ConfigMap that overrides the compose version.
  If you later make the resolver configurable in the app repo (`resolver ${DNS_RESOLVER}`), the ConfigMap can go.
* **Versions** that I could not verify against live registries when writing this: Helm chart ranges
  (`argocd/apps/*.yaml`), `jaegertracing/jaeger:2.10.0`, `splunk/splunk:9.4.3`, `postgres-exporter:v0.17.1`. If an image
  tag does not exist, ArgoCD shows `ImagePullBackOff` - fix the tag in the manifest and push. Kiali/Grafana chart
  value names can shift between major versions; `helm show values <chart> --version <v>` is the reference.
* **Everything was validated offline** (YAML syntax, Kubernetes schema for core kinds). It was **not** run against a real
  cluster in this environment, so expect to fix small environment-specific details on the first run.
* **Argo Rollouts** (canary/blue-green) is the usual next step for progressive delivery; the current strategy is
  zero-downtime rolling updates.
* **Not included:** NetworkPolicies (Istio AuthorizationPolicy covers service-to-service rules), WAF/TLS on the ALB,
  ArgoCD self-management, cost tooling.

## 8.4 Tear everything down

Order matters - delete the Kubernetes load balancers *before* the cluster, or the VPC delete hangs.

```bash
# 1. stop ArgoCD recreating things, then remove LBs / volumes it created
kubectl -n argocd delete application root --cascade=foreground
kubectl get svc -A | grep LoadBalancer          # wait until none are left
kubectl get ingress -A                          # wait until none are left
# 2. delete retained EBS volumes of the database if you really want the data gone
kubectl get pv | grep Retain
# 3. delete the cluster
eksctl delete cluster -f clusters/eks-prod/eksctl-cluster.yaml --disable-nodegroup-eviction
# 4. ECR + Jenkins
for r in frontend backend database; do aws ecr delete-repository --repository-name cardsplit/$r --force; done
```

**Expected output (last lines)**

```
[✔]  all cluster resources were deleted
{ "repository": { "repositoryName": "cardsplit/frontend", ... } }  (x3)
```
