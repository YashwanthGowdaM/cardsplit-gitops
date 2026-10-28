#!/usr/bin/env bash
# Create the 3 ECR repositories (scan on push, immutable tags, KMS/AES encryption, lifecycle policy).
set -euo pipefail
REGION=${AWS_REGION:-ap-south-1}
for svc in frontend backend database; do
  repo="cardsplit/$svc"
  if aws ecr describe-repositories --region "$REGION" --repository-names "$repo" >/dev/null 2>&1; then
    echo "exists : $repo"
  else
    aws ecr create-repository --region "$REGION" --repository-name "$repo" \
      --image-scanning-configuration scanOnPush=true \
      --image-tag-mutability IMMUTABLE \
      --encryption-configuration encryptionType=AES256 \
      --query 'repository.repositoryUri' --output text
  fi
  aws ecr put-lifecycle-policy --region "$REGION" --repository-name "$repo" --lifecycle-policy-text '{
    "rules":[{"rulePriority":1,"description":"keep last 30 images","selection":{"tagStatus":"any","countType":"imageCountMoreThan","countNumber":30},"action":{"type":"expire"}}]}' >/dev/null
done
