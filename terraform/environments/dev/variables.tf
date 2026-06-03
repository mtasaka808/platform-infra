variable "aws_region"     { type = string; default = "us-east-1" }
variable "aws_account_id" { type = string }
variable "github_org"     { type = string }
variable "github_repo"    { type = string; default = "dsca-cdm-demo" }

variable "vpc_cidr"             { type = string; default = "10.10.0.0/16" }
variable "availability_zones"   { type = list(string); default = ["us-east-1a", "us-east-1b"] }
variable "private_subnet_cidrs" { type = list(string); default = ["10.10.0.0/19", "10.10.32.0/19"] }
variable "public_subnet_cidrs"  { type = list(string); default = ["10.10.64.0/20", "10.10.80.0/20"] }

variable "grafana_admin_password" {
  type      = string
  sensitive = true
  default   = "changeme-before-prod"
}
