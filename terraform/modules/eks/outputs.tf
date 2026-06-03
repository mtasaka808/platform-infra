output "cluster_name"              { value = module.eks.cluster_name }
output "cluster_endpoint"          { value = module.eks.cluster_endpoint }
output "cluster_certificate_authority_data" { value = module.eks.cluster_certificate_authority_data }
output "oidc_provider_arn"         { value = module.eks.oidc_provider_arn }
output "alb_controller_role_arn"   { value = module.aws_load_balancer_controller_irsa.iam_role_arn }
output "external_secrets_role_arn" { value = module.external_secrets_irsa.iam_role_arn }
output "github_actions_ecr_role_arn" { value = aws_iam_role.github_actions_ecr.arn }
