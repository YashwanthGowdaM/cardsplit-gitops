# 04 · ECR repositories and the Jenkins CI pipeline

Implements the CI half of the request: **Jenkins builds the 3 images → pushes to AWS ECR → writes the new image
tags into this repo** (which is what triggers ArgoCD).

## 4.1 Create the ECR repositories

```bash
export AWS_REGION=ap-south-1
make ecr
```

**Expected output**

```
123456789012.dkr.ecr.ap-south-1.amazonaws.com/cardsplit/frontend
123456789012.dkr.ecr.ap-south-1.amazonaws.com/cardsplit/backend
123456789012.dkr.ecr.ap-south-1.amazonaws.com/cardsplit/database
```

*Explanation:* repositories are created with **scan on push**, **immutable tags** (a tag like `12-ab12cd3` can never
be overwritten - what ArgoCD deployed is exactly what you can audit) and a lifecycle rule keeping the last 30 images.

## 4.2 Jenkins server

Launch an **Ubuntu 24.04 EC2 instance** (t3.medium, 30 GB, security group: 22 + 8080 from your IP) and give it an
**instance profile** so Jenkins needs no stored AWS keys:

```bash
# on your workstation
aws iam create-role --role-name cardsplit-jenkins --assume-role-policy-document '{
 "Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam put-role-policy --role-name cardsplit-jenkins --policy-name ecr-push \
  --policy-document file://clusters/eks-prod/iam/jenkins-ecr-policy.json
aws iam create-instance-profile --instance-profile-name cardsplit-jenkins
aws iam add-role-to-instance-profile --instance-profile-name cardsplit-jenkins --role-name cardsplit-jenkins
aws ec2 associate-iam-instance-profile --instance-id i-0123456789abcdef0 --iam-instance-profile Name=cardsplit-jenkins
```

**Expected output (last command)**

```json
{ "IamInstanceProfileAssociation": { "State": "associating", "InstanceId": "i-0123456789abcdef0", ... } }
```

SSH into the instance and install the tooling:

```bash
sudo apt-get update && sudo apt-get install -y ca-certificates curl gnupg git unzip fontconfig openjdk-21-jre docker.io
# Jenkins LTS: follow the current official instructions (the repository signing key changes over time):
#   https://www.jenkins.io/doc/book/installing/linux/#debianubuntu
# AWS CLI v2, kustomize, yq, (optional) trivy
curl -sSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/aws.zip && unzip -q /tmp/aws.zip -d /tmp && sudo /tmp/aws/install
curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash && sudo mv kustomize /usr/local/bin/
sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 && sudo chmod +x /usr/local/bin/yq
sudo usermod -aG docker jenkins && sudo systemctl restart jenkins   # run after Jenkins is installed
```

Verify as the jenkins user:

```bash
sudo -u jenkins bash -c 'docker ps && aws sts get-caller-identity --query Arn --output text && kustomize version && yq --version'
```

**Expected output**

```
CONTAINER ID   IMAGE   COMMAND   CREATED   STATUS   PORTS   NAMES
arn:aws:sts::123456789012:assumed-role/cardsplit-jenkins/i-0123456789abcdef0
v5.x.x
yq (https://github.com/mikefarah/yq/) version v4.x.x
```

The `assumed-role/cardsplit-jenkins` line proves the agent uses the instance role.

## 4.3 Configure Jenkins

1. Open `http://<jenkins-ip>:8080`, unlock with `sudo cat /var/lib/jenkins/secrets/initialAdminPassword`, install the
   suggested plugins, plus **GitHub**, **Pipeline: Multibranch**, **Timestamps**, **Workspace Cleanup**.
2. *Manage Jenkins → Credentials → (global) → Add*: kind **Username with password**,
   ID **`github-gitops-pat`**, username = your GitHub user, password = the fine-grained token (write access to
   the GitOps repo). If the **app repo is private** add a second credential for it and select it in the job.
3. The built-in node must have the label `docker`: *Manage Jenkins → Nodes → Built-In Node → Labels = `docker`*.

## 4.4 Put the Jenkinsfile into the APP repo

```bash
cd ../CreditCardBillSplitter          # your application repository
cp ../cardsplit-gitops/ci/app-repo/Jenkinsfile ./Jenkinsfile
git add Jenkinsfile && git commit -m "ci: add Jenkins pipeline" && git push
```

**Expected output**

```
[main 8a1b2c3] ci: add Jenkins pipeline
 1 file changed, 112 insertions(+)
```

## 4.5 Create the Multibranch job and the webhook

1. Jenkins → **New Item** → `cardsplit-app` → *Multibranch Pipeline* → Branch Source: GitHub/Git → the app repo URL
   → *Scan Multibranch Pipeline Triggers*: 1 minute (fallback).
2. GitHub app repo → *Settings → Webhooks → Add*: Payload URL `http://<jenkins-ip>:8080/github-webhook/`,
   content type `application/json`, event: *Just the push event*.

## 4.6 First build

Click **Build Now** on the `main` branch (or push any commit).

**Expected console output (abridged)**

```
[Pipeline] stage (Prepare)        ... IMAGE_TAG = 1-3fa9c1e
[Pipeline] stage (Build images)   ... Successfully tagged 123456789012.dkr.ecr.ap-south-1.amazonaws.com/cardsplit/frontend:1-3fa9c1e (x3, parallel)
[Pipeline] stage (Scan images (Trivy)) ... trivy not installed on this agent - skipping vulnerability scan
[Pipeline] stage (Push to ECR)    ... 1-3fa9c1e: digest: sha256:... size: 1783   (x3)
[Pipeline] stage (Update GitOps repo)
    [main 91c4d0e] ci(dev): deploy cardsplit 1-3fa9c1e
    To https://github.com/<you>/cardsplit-gitops.git   a1b2c3d..91c4d0e  HEAD -> main
Finished: SUCCESS
```

Verify the images and the commit:

```bash
aws ecr describe-images --repository-name cardsplit/backend --query 'imageDetails[].imageTags' --output text
git -C ../cardsplit-gitops pull && git -C ../cardsplit-gitops log --oneline -2
grep -A1 "name: cardsplit/backend" ../cardsplit-gitops/apps/cardsplit/overlays/dev/kustomization.yaml
```

**Expected output**

```
1-3fa9c1e
91c4d0e ci(dev): deploy cardsplit 1-3fa9c1e
- name: cardsplit/backend
  newName: 123456789012.dkr.ecr.ap-south-1.amazonaws.com/cardsplit/backend
  newTag: "1-3fa9c1e"
```

## 4.7 Give PROD the same tags (promotion job)

PROD is never touched by the app pipeline. Create a **Pipeline** job `cardsplit-promote-prod` (Pipeline script from
SCM → the GitOps repo → Script Path `ci/gitops-repo/Jenkinsfile.promote`) and run it; approve the prompt.

**Expected output**

```
== DEV  ==  ... newTag: "1-3fa9c1e"
== PROD ==  ... newTag: "0.0.0"
Promote the DEV image tags to PROD?   [Promote]
[main 5d6e7f8] release(prod): promote dev image tags (build 1)
Finished: SUCCESS
```

> Do 4.6 and 4.7 **before** chapter 05, otherwise the pods start with the placeholder tag `0.0.0` and sit in
> `ImagePullBackOff` until the first real tag arrives.
