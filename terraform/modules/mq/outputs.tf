output "broker_id"             { value = aws_mq_broker.this.id }
output "endpoint"              { value = aws_mq_broker.this.instances[0].endpoints[0] }
output "mq_url_secret_arn"     { value = aws_secretsmanager_secret.mq_url.arn }
output "mq_url_secret_name"    { value = aws_secretsmanager_secret.mq_url.name }
