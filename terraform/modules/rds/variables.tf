variable "project"           { type = string }
variable "environment"       { type = string }
variable "service_name"      { type = string }
variable "subnet_ids"        { type = list(string) }
variable "security_group_id" { type = string }
variable "database_name"     { type = string }
variable "database_user"     { type = string; default = "appuser" }
variable "postgres_version"  { type = string; default = "16.4" }
variable "instance_class"    { type = string; default = "db.t3.medium" }
variable "allocated_storage" { type = number; default = 20 }
variable "tags"              { type = map(string); default = {} }
