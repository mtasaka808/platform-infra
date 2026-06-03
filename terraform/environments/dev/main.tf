terraform {
  required_version = ">= 1.9"
  required_providers {
    aws    = { source = "hashicorp/aws";    version = "~> 5.0" }
    random = { source = "hashicorp/random"; version = "~> 3.0" }
  }
  backend "s3" {
    # Fill in: terraform/environments/dev/backend.tfvars
    # terraform init -backend-config=backend.tfvars
  }
}

provider "aws" {
  region = var.aws_region
  default_tags { tags = local.common_tags }
}

locals {
  project     = "cdm"
  environment = "dev"
  common_tags = {
    Project     = local.project
    Environment = local.environment
    ManagedBy   = "terraform"
  }
}

module "networking" {
  source = "../../modules/networking"

  project     = local.project
  environment = local.environment
  vpc_cidr    = var.vpc_cidr

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
  source = "../../modules/eks"

  project            = local.project
  environment        = local.environment
  vpc_id             = module.networking.vpc_id
  private_subnet_ids = module.networking.private_subnet_ids
  aws_region         = var.aws_region
  aws_account_id     = var.aws_account_id
  github_org         = var.github_org
  github_repo        = var.github_repo
  node_instance_types = ["t3.medium"]
  node_min_size      = 1
  node_max_size      = 3
  node_desired_size  = 2
  tags               = local.common_tags
}

module "rds_grants" {
  source = "../../modules/rds"

  project           = local.project
  environment       = local.environment
  service_name      = "grants-mgmt-api"
  database_name     = "grantsMgmt"
  subnet_ids        = module.networking.private_subnet_ids
  security_group_id = module.networking.rds_sg_id
  instance_class    = "db.t3.medium"
  tags              = local.common_tags
}

module "mq" {
  source = "../../modules/mq"

  project           = local.project
  environment       = local.environment
  subnet_ids        = module.networking.private_subnet_ids
  security_group_id = module.networking.mq_sg_id
  instance_type     = "mq.t3.micro"
  tags              = local.common_tags
}
