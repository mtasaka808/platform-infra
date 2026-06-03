resource "random_password" "mq" {
  length  = 32
  special = false
}

resource "aws_mq_broker" "this" {
  broker_name        = "${var.project}-${var.environment}"
  engine_type        = "RabbitMQ"
  engine_version     = var.rabbitmq_version
  host_instance_type = var.instance_type
  deployment_mode    = var.environment == "prod" ? "CLUSTER_MULTI_AZ" : "SINGLE_INSTANCE"

  subnet_ids         = var.environment == "prod" ? var.subnet_ids : [var.subnet_ids[0]]
  security_groups    = [var.security_group_id]
  publicly_accessible = false

  user {
    username = "platform"
    password = random_password.mq.result
  }

  encryption_options {
    use_aws_owned_key = true
  }

  tags = var.tags
}

resource "aws_secretsmanager_secret" "mq_url" {
  name                    = "${var.project}/shared/rabbitmq-url"
  recovery_window_in_days = var.environment == "prod" ? 30 : 0
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "mq_url" {
  secret_id = aws_secretsmanager_secret.mq_url.id
  secret_string = jsonencode({
    url      = "amqps://platform:${random_password.mq.result}@${trimprefix(aws_mq_broker.this.instances[0].endpoints[0], "amqps://")}"
    username = "platform"
    password = random_password.mq.result
    endpoint = aws_mq_broker.this.instances[0].endpoints[0]
  })
}
