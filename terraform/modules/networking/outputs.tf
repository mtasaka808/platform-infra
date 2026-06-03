output "vpc_id"              { value = module.vpc.vpc_id }
output "private_subnet_ids"  { value = module.vpc.private_subnets }
output "public_subnet_ids"   { value = module.vpc.public_subnets }
output "rds_sg_id"           { value = aws_security_group.rds.id }
output "mq_sg_id"            { value = aws_security_group.mq.id }
