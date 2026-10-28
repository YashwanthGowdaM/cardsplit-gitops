# 02 · Create the EKS cluster (node groups, taint, IRSA, EBS CSI)

Implements: **node groups for affinity / taints (14-16)**, **EBS CSI for StorageClass/PVC (1)**, **IRSA for the
Load Balancer Controller (12-13) and Cluster Autoscaler (2)**.

## 2.1 Fill in your values (do this once for the whole repo)

```bash
cd cardsplit-gitops
./scripts/configure.sh
```

Answer the prompts (example):

```
AWS account id (12 digits) []: 123456789012
AWS region [ap-south-1]:
EKS cluster name [cardsplit-eks]:
HTTPS URL of THIS repo (e.g. https://github.com/you/cardsplit-gitops.git) []: https://github.com/yashwanth/cardsplit-gitops.git
CIDR allowed to reach ArgoCD/Grafana/Kiali/Jaeger/Splunk (use YOUR_IP/32!) [0.0.0.0/0]: 203.0.113.25/32
```

**Expected output**

```
Configured. Remaining tokens (should be none):
  none
```

> Tip: find your public IP with `curl -s https://checkip.amazonaws.com`. Using `YOUR_IP/32` keeps the admin UIs
> (which are on public load balancers) reachable only from you. Your **end users** still reach the app through the ALB,
> which is not restricted.

## 2.2 Create the cluster (≈ 20-25 minutes)

```bash
eksctl create cluster -f clusters/eks-prod/eksctl-cluster.yaml
```

**Expected output (abridged, last lines)**

```
2026-10-28 06:12:01 [ℹ]  eksctl version 0.2xx.0
2026-10-28 06:12:01 [ℹ]  using region ap-south-1
...
2026-10-28 06:27:44 [ℹ]  nodegroup "ng-app" has 2 node(s)
2026-10-28 06:27:44 [ℹ]  nodegroup "ng-data" has 1 node(s)
2026-10-28 06:27:44 [ℹ]  nodegroup "ng-platform" has 2 node(s)
2026-10-28 06:27:46 [✔]  created 3 managed nodegroup(s) in cluster "cardsplit-eks"
2026-10-28 06:27:47 [✔]  all EKS cluster resources for "cardsplit-eks" have been created
2026-10-28 06:27:48 [ℹ]  kubectl command should work with "~/.kube/config", try 'kubectl get nodes'
```

## 2.3 Verify nodes, labels and the taint

```bash
kubectl get nodes -L workload,topology.kubernetes.io/zone
```

**Expected output**

```
NAME                                          STATUS   ROLES    AGE   VERSION               WORKLOAD   ZONE
ip-192-168-12-4.ap-south-1.compute.internal   Ready    <none>   4m    v1.36.x-eks-xxxxxxx   app        ap-south-1a
ip-192-168-45-9.ap-south-1.compute.internal   Ready    <none>   4m    v1.36.x-eks-xxxxxxx   app        ap-south-1b
ip-192-168-18-77.ap-south-1.compute.internal  Ready    <none>   4m    v1.36.x-eks-xxxxxxx   data       ap-south-1a
ip-192-168-30-2.ap-south-1.compute.internal   Ready    <none>   4m    v1.36.x-eks-xxxxxxx   platform   ap-south-1a
ip-192-168-70-8.ap-south-1.compute.internal   Ready    <none>   4m    v1.36.x-eks-xxxxxxx   platform   ap-south-1c
```

```bash
kubectl get nodes -l workload=data -o jsonpath='{.items[0].spec.taints}'; echo
```

**Expected output**

```
[{"effect":"NoSchedule","key":"dedicated","value":"data"}]
```

*Explanation:* only pods that **tolerate** `dedicated=data:NoSchedule` can run on the data node - that is how the
database gets a dedicated node and everything else is kept off it.

## 2.4 Verify IRSA service accounts and the EBS CSI driver

```bash
kubectl -n kube-system get sa aws-load-balancer-controller cluster-autoscaler
kubectl -n kube-system get pods -l app.kubernetes.io/name=aws-ebs-csi-driver
```

**Expected output**

```
NAME                           SECRETS   AGE
aws-load-balancer-controller   0         3m
cluster-autoscaler             0         3m

NAME                                  READY   STATUS    RESTARTS   AGE
ebs-csi-controller-6f9c7d8b4-abcde    6/6     Running   0          4m
ebs-csi-controller-6f9c7d8b4-fghij    6/6     Running   0          4m
ebs-csi-node-xxxxx                    3/3     Running   0          4m
...
```

## 2.5 Make our StorageClass the default (remove gp2 as default)

EKS ships a `gp2` default StorageClass. ArgoCD will create `gp3-delete` (default) in chapter 05; to avoid two
defaults, un-default gp2 now:

```bash
kubectl patch storageclass gp2 -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
```

**Expected output**

```
storageclass.storage.k8s.io/gp2 patched
```

## 2.6 (Optional) Map IAM roles to the Kubernetes groups used by the RBAC manifests

The repo defines groups `cardsplit-developers`, `cardsplit-viewers`, `platform-viewers`. Bind an IAM role/user to a
group with an EKS access entry:

```bash
aws eks create-access-entry --cluster-name cardsplit-eks \
  --principal-arn arn:aws:iam::123456789012:role/CardSplitDevelopers \
  --kubernetes-groups cardsplit-developers
```

**Expected output**

```json
{ "accessEntry": { "clusterName": "cardsplit-eks", "kubernetesGroups": ["cardsplit-developers"], ... } }
```

Test later with `kubectl auth can-i` (chapter 06, requirement 5).
