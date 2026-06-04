module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name                   = "${var.project}-${var.environment}"
  cluster_version                = var.kubernetes_version
  cluster_endpoint_public_access = var.environment != "prod"

  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids

  # IRSA — required for aws-load-balancer-controller and external-secrets
  enable_irsa = true

  eks_managed_node_groups = {
    general = {
      instance_types = var.node_instance_types
      min_size       = var.node_min_size
      max_size       = var.node_max_size
      desired_size   = var.node_desired_size

      labels = {
        role = "general"
      }
    }
  }

  # Cluster addons
  cluster_addons = {
    coredns    = { most_recent = true }
    kube-proxy = { most_recent = true }
    vpc-cni    = { most_recent = true }
    aws-ebs-csi-driver = { most_recent = true }
  }

  tags = var.tags
}

# ── aws-load-balancer-controller ─────────────────────────────────────────────
module "aws_load_balancer_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name                              = "${var.project}-${var.environment}-alb-controller"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
  tags = var.tags
}

# ── external-secrets-operator ────────────────────────────────────────────────
module "external_secrets_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name                             = "${var.project}-${var.environment}-external-secrets"
  attach_external_secrets_policy        = true
  external_secrets_ssm_parameter_arns   = ["arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:parameter/${var.project}/*"]
  external_secrets_secrets_manager_arns = ["arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:${var.project}/*"]

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["external-secrets:external-secrets"]
    }
  }
  tags = var.tags
}

# ── Karpenter controller IRSA ────────────────────────────────────────────────
module "karpenter_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name                          = "${var.project}-${var.environment}-karpenter"
  attach_karpenter_controller_policy = true

  karpenter_controller_cluster_id       = module.eks.cluster_name
  karpenter_controller_node_iam_role_arns = [aws_iam_role.karpenter_node.arn]

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["${local.karpenter_namespace}:karpenter"]
    }
  }
  tags = var.tags
}

locals {
  karpenter_namespace = "karpenter"
}

# IAM role assumed by EC2 nodes that Karpenter provisions
resource "aws_iam_role" "karpenter_node" {
  name = "${var.project}-${var.environment}-karpenter-node"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "karpenter_node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ])
  role       = aws_iam_role.karpenter_node.name
  policy_arn = each.value
}

resource "aws_iam_instance_profile" "karpenter_node" {
  name = "${var.project}-${var.environment}-karpenter-node"
  role = aws_iam_role.karpenter_node.name
  tags = var.tags
}

# EKS node access entry so Karpenter nodes can join the cluster
resource "aws_eks_access_entry" "karpenter_node" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.karpenter_node.arn
  type          = "EC2_LINUX"
}

# SQS queue for spot interruption / rebalance notifications
resource "aws_sqs_queue" "karpenter" {
  name                      = "${var.project}-${var.environment}-karpenter"
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true
  tags                      = var.tags
}

resource "aws_sqs_queue_policy" "karpenter" {
  queue_url = aws_sqs_queue.karpenter.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowEventBridge"
      Effect = "Allow"
      Principal = { Service = ["events.amazonaws.com", "sqs.amazonaws.com"] }
      Action   = "sqs:SendMessage"
      Resource = aws_sqs_queue.karpenter.arn
    }]
  })
}

# EventBridge rules → SQS for spot interruption, rebalance, state changes
locals {
  karpenter_event_rules = {
    spot_interruption = {
      source      = ["aws.ec2"]
      detail_type = ["EC2 Spot Instance Interruption Warning"]
    }
    rebalance = {
      source      = ["aws.ec2"]
      detail_type = ["EC2 Instance Rebalance Recommendation"]
    }
    instance_state_change = {
      source      = ["aws.ec2"]
      detail_type = ["EC2 Instance State-change Notification"]
    }
    scheduled_change = {
      source      = ["aws.health"]
      detail_type = ["AWS Health Event"]
    }
  }
}

resource "aws_cloudwatch_event_rule" "karpenter" {
  for_each    = local.karpenter_event_rules
  name        = "${var.project}-${var.environment}-karpenter-${each.key}"
  description = "Karpenter: ${each.key}"
  event_pattern = jsonencode({
    source      = each.value.source
    detail-type = each.value.detail_type
  })
  tags = var.tags
}

resource "aws_cloudwatch_event_target" "karpenter" {
  for_each  = aws_cloudwatch_event_rule.karpenter
  rule      = each.value.name
  target_id = "karpenter-sqs"
  arn       = aws_sqs_queue.karpenter.arn
}

# ── Velero IRSA ───────────────────────────────────────────────────────────────
resource "aws_s3_bucket" "velero" {
  bucket        = "${var.project}-${var.environment}-velero-backup"
  force_destroy = var.environment != "prod"
  tags          = var.tags
}

resource "aws_s3_bucket_versioning" "velero" {
  bucket = aws_s3_bucket.velero.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "velero" {
  bucket = aws_s3_bucket.velero.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "aws:kms" }
  }
}

module "velero_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name             = "${var.project}-${var.environment}-velero"
  attach_velero_policy  = true
  velero_s3_bucket_arns = [aws_s3_bucket.velero.arn]

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["velero:velero"]
    }
  }
  tags = var.tags
}

# ── CI role for OIDC image push (GitHub Actions) ─────────────────────────────
data "aws_iam_policy_document" "github_actions_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = ["arn:aws:iam::${var.aws_account_id}:oidc-provider/token.actions.githubusercontent.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_org}/${var.github_repo}:*"]
    }
  }
}

resource "aws_iam_role" "github_actions_ecr" {
  name               = "${var.project}-${var.environment}-github-actions-ecr"
  assume_role_policy = data.aws_iam_policy_document.github_actions_trust.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "github_actions_ecr" {
  role       = aws_iam_role.github_actions_ecr.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}
