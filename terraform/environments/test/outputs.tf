output "cluster_name"              { value = module.eks.cluster_name }
output "ecr_repository_urls"       { value = module.ecr.repository_urls }
output "github_actions_ecr_role_arn" { value = module.eks.github_actions_ecr_role_arn }
output "rds_grants_secret_name"    { value = module.rds_grants.database_url_secret_name }
output "mq_secret_name"            { value = module.mq.mq_url_secret_name }
