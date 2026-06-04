terraform {
  required_version = ">= 1.9"
  required_providers {
    aws    = { source = "hashicorp/aws";    version = "~> 5.0" }
    random     = { source = "hashicorp/random";    version = "~> 3.0" }
    helm       = { source = "hashicorp/helm";      version = "~> 2.16" }
    kubernetes = { source = "hashicorp/kubernetes"; version = "~> 2.33" }
    kubectl    = { source = "gavinbunney/kubectl"; version = "~> 1.14" }
  }
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region
  default_tags { tags = local.common_tags }
}

locals {
  project     = "cdm"
  environment = "prod"
  common_tags = {
    Project     = local.project
    Environment = local.environment
    ManagedBy   = "terraform"
  }
}

module "networking" {
  source               = "../../modules/networking"
  project              = local.project
  environment          = local.environment
  vpc_cidr             = var.vpc_cidr
  availability_zones   = var.availability_zones
  private_subnet_cidrs = var.private_subnet_cidrs
  public_subnet_cidrs  = var.public_subnet_cidrs
  tags                 = local.common_tags
}

module "ecr" {
  source  = "../../modules/ecr"
  project = local.project
  tags    = local.common_tags
}

module "eks" {
  source              = "../../modules/eks"
  project             = local.project
  environment         = local.environment
  vpc_id              = module.networking.vpc_id
  private_subnet_ids  = module.networking.private_subnet_ids
  aws_region          = var.aws_region
  aws_account_id      = var.aws_account_id
  github_org          = var.github_org
  github_repo         = var.github_repo
  node_instance_types = ["m5.xlarge", "m5a.xlarge"]
  node_min_size       = 3
  node_max_size       = 10
  node_desired_size   = 3
  tags                = local.common_tags
}

module "rds_grants" {
  source            = "../../modules/rds"
  project           = local.project
  environment       = local.environment
  service_name      = "grants-mgmt-api"
  database_name     = "grantsMgmt"
  subnet_ids        = module.networking.private_subnet_ids
  security_group_id = module.networking.rds_sg_id
  instance_class    = "db.r6g.large"
  allocated_storage = 100
  tags              = local.common_tags
}

module "mq" {
  source            = "../../modules/mq"
  project           = local.project
  environment       = local.environment
  subnet_ids        = module.networking.private_subnet_ids
  security_group_id = module.networking.mq_sg_id
  instance_type     = "mq.m5.large"
  tags              = local.common_tags
}

data "aws_eks_cluster_auth" "this" { name = module.eks.cluster_name }

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
}
provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
  load_config_file       = false
}

module "addons" {
  source = "../../modules/addons"
  cluster_name            = module.eks.cluster_name
  cluster_endpoint        = module.eks.cluster_endpoint
  aws_region              = var.aws_region
  environment             = local.environment
  base_domain             = var.base_domain
  karpenter_role_arn       = module.eks.karpenter_role_arn
  karpenter_node_role_name = module.eks.karpenter_node_role_name
  karpenter_queue_name     = module.eks.karpenter_queue_name
  velero_role_arn          = module.eks.velero_role_arn
  velero_bucket            = module.eks.velero_bucket
  grafana_admin_password   = var.grafana_admin_password
}
