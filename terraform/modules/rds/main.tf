resource "random_password" "db" {
  length  = 32
  special = false
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.project}-${var.environment}-${var.service_name}"
  subnet_ids = var.subnet_ids
  tags       = var.tags
}

resource "aws_db_instance" "this" {
  identifier        = "${var.project}-${var.environment}-${var.service_name}"
  engine            = "postgres"
  engine_version    = var.postgres_version
  instance_class    = var.instance_class
  allocated_storage = var.allocated_storage
  storage_encrypted = true

  db_name  = var.database_name
  username = var.database_user
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.security_group_id]

  backup_retention_period = var.environment == "prod" ? 14 : 3
  deletion_protection     = var.environment == "prod"
  skip_final_snapshot     = var.environment != "prod"
  multi_az                = var.environment == "prod"

  performance_insights_enabled = true
  tags = var.tags
}

resource "aws_secretsmanager_secret" "db_url" {
  name                    = "${var.project}/${var.service_name}/database-url"
  recovery_window_in_days = var.environment == "prod" ? 30 : 0
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "db_url" {
  secret_id = aws_secretsmanager_secret.db_url.id
  secret_string = jsonencode({
    url      = "postgresql://${var.database_user}:${random_password.db.result}@${aws_db_instance.this.endpoint}/${var.database_name}"
    host     = aws_db_instance.this.address
    port     = tostring(aws_db_instance.this.port)
    database = var.database_name
    username = var.database_user
    password = random_password.db.result
  })
}
