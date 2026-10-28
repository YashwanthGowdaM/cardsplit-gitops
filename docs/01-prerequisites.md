# 01 · Prerequisites

You need an AWS account, a GitHub account, and a workstation (Linux/macOS/WSL) to drive everything from.

## 1.1 Tools on your workstation

| Tool | Version | Why |
|---|---|---|
| aws CLI | v2 | ECR, IAM, EKS |
| eksctl | ≥ 0.200 | creates the cluster |
| kubectl | 1.35–1.37 (±1 minor of 1.36) | cluster access |
| helm | 3.x | bootstrap ArgoCD + Sealed Secrets |
| kubeseal | matches controller | encrypts secrets |
| kustomize | 5.x | local build/validate (optional but recommended) |
| git, yq (mikefarah v4), python3 | any recent | scripts |

Check:

```bash
aws --version; eksctl version; kubectl version --client; helm version --short; kubeseal --version; kustomize version; yq --version
```

**Expected output** (versions will differ):

```
aws-cli/2.x.x Python/3.x Linux/...
0.2xx.0
Client Version: v1.36.x
v3.1x.x+g...
kubeseal version: 0.3x.x
v5.x.x
yq (https://github.com/mikefarah/yq/) version v4.x.x
```

## 1.2 AWS access

```bash
aws sts get-caller-identity
```

**Expected output**

```json
{
    "UserId": "AIDA...",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012:user/yashwanth"
}
```

Your identity needs permission to create EKS clusters, VPCs, IAM roles, ECR repositories and EC2 (AdministratorAccess
is easiest for a lab). Note the **Account** number - you will use it in step 03.

## 1.3 Create the GitOps repository on GitHub

1. GitHub → **New repository** → name `cardsplit-gitops` → *Private* → no README (empty).
2. Create a **fine-grained personal access token** (Settings → Developer settings):
   * Repository access: `cardsplit-gitops` only
   * Permissions: **Contents: Read and write**
   * Save the token; Jenkins and ArgoCD will use it.

## 1.4 Unpack this repository

```bash
unzip cardsplit-gitops.zip && cd cardsplit-gitops
git init -b main
ls
```

**Expected output**

```
Makefile  README.md  apps  argocd  bootstrap  ci  clusters  docs  platform  scripts
```

## 1.5 Cost warning

The lab stack (≈ 2×t3.medium app + 1×t3.medium data + 2×t3.xlarge platform nodes, 2 ALBs (dev + prod), 5 NLBs, EBS volumes, NAT
gateway) costs roughly **USD 18-25 per day** (rough estimate - check the AWS pricing page for your region). Delete everything with `eksctl delete cluster` (chapter 08) when done.
