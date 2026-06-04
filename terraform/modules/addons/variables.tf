variable "cluster_name"     { type = string }
variable "cluster_endpoint" { type = string }
variable "aws_region"       { type = string }
variable "environment"      { type = string }

# IAM role ARNs and supporting resources (outputs from eks module)
variable "cert_manager_role_arn"     { type = string; default = "" }
variable "karpenter_role_arn"        { type = string }
variable "karpenter_node_role_name"  { type = string }
variable "karpenter_queue_name"      { type = string }
variable "velero_role_arn"           { type = string }
variable "velero_bucket"             { type = string }

# DNS base domain for Istio VirtualServices
variable "base_domain" { type = string; description = "e.g. cdm.example.gov" }

# Optional pre-existing S3 buckets for Loki/Tempo (empty = auto-create)
variable "loki_s3_bucket"  { type = string; default = "" }
variable "tempo_s3_bucket" { type = string; default = "" }

# Secrets (inject from Secrets Manager or Vault in real usage)
variable "grafana_admin_password" {
  type      = string
  sensitive = true
}

# Chart versions — pin and bump deliberately
variable "cert_manager_version"    { type = string; default = "v1.16.2" }
variable "istio_version"           { type = string; default = "1.24.2" }
variable "kiali_version"           { type = string; default = "2.4.0" }
variable "prometheus_stack_version" { type = string; default = "67.9.0" }
variable "loki_version"            { type = string; default = "6.24.0" }
variable "promtail_version"        { type = string; default = "6.16.6" }
variable "tempo_version"           { type = string; default = "1.21.0" }
variable "otel_operator_version"   { type = string; default = "0.73.0" }
variable "karpenter_version"       { type = string; default = "1.1.1" }
variable "falco_version"           { type = string; default = "4.11.0" }
variable "kyverno_version"         { type = string; default = "3.3.4" }
variable "velero_version"          { type = string; default = "8.1.0" }
