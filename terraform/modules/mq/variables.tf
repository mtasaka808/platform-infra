variable "project"           { type = string }
variable "environment"       { type = string }
variable "subnet_ids"        { type = list(string) }
variable "security_group_id" { type = string }
variable "rabbitmq_version"  { type = string; default = "3.13" }
variable "instance_type"     { type = string; default = "mq.t3.micro" }
variable "tags"              { type = map(string); default = {} }
