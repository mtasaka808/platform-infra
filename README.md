# CDM Platform Infrastructure

Infrastructure-as-Code for the Case Development Modernization (CDM) platform.

This repo owns:
- **Terraform** — EKS cluster, VPC, RDS, Amazon MQ, ECR, IAM (dev / test / prod)
- **Helm** — Production-grade chart shared by all CDM services
- **ArgoCD** — ApplicationSets that sync each environment when image tags are bumped
- **GitHub Actions** — Terraform plan/apply on PR/merge; Helm lint on chart changes

The app-team repo (`dsca-cdm-demo`) never touches this repo directly. CI opens an automated PR bumping the image tag in `environments/<env>/apps/<service>.yaml` after a successful ECR push.

---

## Repository structure

```
terraform/
├── modules/          # reusable modules (networking, eks, rds, mq, ecr)
└── environments/
    ├── dev/          # development cluster
    ├── test/         # test / UAT cluster
    └── prod/         # production cluster

helm/
└── cdm-service/      # shared Helm chart (Deployment, Service, Ingress, HPA, PDB, ExternalSecret)

environments/
├── dev/apps/         # per-service Helm values for dev  ← bumped by app CI
├── test/apps/        # per-service Helm values for test ← bumped by app CI
└── prod/apps/        # per-service Helm values for prod ← bumped by app CI

argocd/
├── bootstrap/        # ClusterSecretStore for External Secrets Operator
├── projects/         # ArgoCD project definitions
└── applicationsets/  # one ApplicationSet per environment

.github/workflows/
├── terraform-plan.yml   # PR: plan changed environments, post to PR
├── terraform-apply.yml  # merge to main: apply changed environments
└── helm-lint.yml        # PR: helm lint + template all service values
```

---

## First-time setup

### 1. Bootstrap Terraform state backend (once per AWS account)

```bash
aws s3 mb s3://your-org-terraform-state --region us-east-1
aws dynamodb create-table \
  --table-name your-org-terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

### 2. Provision dev infrastructure

```bash
cd terraform/environments/dev
cp terraform.tfvars.example terraform.tfvars   # fill in values
cp backend.tfvars.example   backend.tfvars     # fill in values
terraform init -backend-config=backend.tfvars
terraform plan
terraform apply
```

### 3. Configure GitHub repository secrets

After `terraform apply`, get the outputs:

```bash
terraform output github_actions_ecr_role_arn  # → AWS_ECR_ROLE_ARN in app repo
terraform output cluster_name                 # for kubeconfig
```

Set in the **app repo** (`dsca-cdm-demo`) secrets:
- `AWS_ECR_ROLE_ARN` — from terraform output above
- `AWS_REGION` — e.g. `us-east-1`
- `INFRA_REPO_TOKEN` — GitHub PAT with `repo` write access to this repo
- `INFRA_REPO_OWNER` — your GitHub org/username

Set in **this repo** secrets:
- `AWS_TF_ROLE_ARN_DEV` — IAM role ARN with Terraform permissions (dev account)
- `AWS_TF_ROLE_ARN_TEST` — IAM role ARN (test account)
- `AWS_TF_ROLE_ARN_PROD` — IAM role ARN (prod account)

### 4. Install cluster add-ons

```bash
# Get kubeconfig
aws eks update-kubeconfig --name cdm-dev --region us-east-1

# aws-load-balancer-controller
helm repo add eks https://aws.github.io/eks-charts
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=cdm-dev \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$(terraform output -raw alb_controller_role_arn)

# external-secrets-operator
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$(terraform output -raw external_secrets_role_arn)

# ArgoCD
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd -n argocd --create-namespace

# Apply ClusterSecretStore + ArgoCD project + ApplicationSets
kubectl apply -f argocd/bootstrap/cluster-secret-store.yaml
kubectl apply -f argocd/projects/cdm.yaml -n argocd
kubectl apply -f argocd/applicationsets/cdm-dev.yaml -n argocd
```

### 5. Enable deployments in the app repo

In `dsca-cdm-demo` → Settings → Variables → New variable:
```
PUBLISH_ENABLED = true
```

Once set, merges to `develop` will automatically build images, push to ECR, and open a PR here bumping the image tags. ArgoCD syncs on merge.

---

## Deployment flow

```
app-team push to develop
      │
      ▼
CI builds docker images
CI pushes to ECR (tagged dev-{sha})
CI opens PR in this repo:
  environments/dev/apps/<service>.yaml: tag: dev-{sha}
      │
      ▼ (merge PR)
ArgoCD detects change in environments/dev/
ArgoCD syncs cdm-dev ApplicationSet
Pods roll out with new image
```

---

## Secrets managed by this repo

All secrets live in AWS Secrets Manager under the `cdm/` prefix.
External Secrets Operator syncs them into Kubernetes secrets at pod startup.

| Secret path | Contents | Used by |
|---|---|---|
| `cdm/grants-mgmt-api/database-url` | PostgreSQL connection string | grants-mgmt-api |
| `cdm/shared/rabbitmq-url` | Amazon MQ AMQPS URL | all event-driven services |
| `cdm/shared/jwt-secret` | HS256 signing key (Phase 1) | grants-mgmt-api |
| `cdm/grants-mgmt-api/cors-origins` | Allowed browser origins | grants-mgmt-api |

Secrets are created by Terraform (`rds` and `mq` modules) and may also be managed manually for shared secrets like `jwt-secret`.
