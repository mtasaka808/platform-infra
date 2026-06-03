variable "project"            { type = string }
variable "environment"        { type = string }
variable "kubernetes_version" { type = string; default = "1.32" }
variable "vpc_id"             { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "aws_region"         { type = string }
variable "aws_account_id"     { type = string }
variable "github_org"         { type = string }
variable "github_repo"        { type = string }
variable "node_instance_types" { type = list(string); default = ["t3.medium"] }
variable "node_min_size"       { type = number; default = 1 }
variable "node_max_size"       { type = number; default = 5 }
variable "node_desired_size"   { type = number; default = 2 }
variable "tags"               { type = map(string); default = {} }
