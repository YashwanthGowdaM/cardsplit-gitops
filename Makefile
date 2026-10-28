.PHONY: configure validate validate-strict seal ecr pin
configure:        ## replace the placeholder tokens with your AWS and Git values
	./scripts/configure.sh
validate:         ## offline checks (warns on placeholders)
	./scripts/validate.sh
validate-strict:  ## offline checks (fails on placeholders) - run before the first push
	./scripts/validate.sh --strict
seal:             ## encrypt the placeholder secrets with kubeseal
	./scripts/seal-secrets.sh
ecr:              ## create the 3 ECR repositories
	./scripts/create-ecr-repos.sh
pin:              ## pin Helm chart versions in argocd/apps
	./scripts/pin-chart-versions.sh
