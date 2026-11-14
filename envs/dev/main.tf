# Artifacts bucket is long-lived (bootstrap); look it up instead of creating it.
data "aws_s3_bucket" "artifacts" {
  bucket = var.artifacts_bucket_name
}

module "network" {
  source = "../../modules/network"

  name_prefix         = var.name_prefix
  vpc_cidr            = "10.20.0.0/16"
  azs                 = var.azs
  public_subnet_cidrs = ["10.20.1.0/24", "10.20.2.0/24"]
  allowed_cidr        = var.allowed_cidr
}

module "nlb" {
  source = "../../modules/nlb"

  name_prefix          = var.name_prefix
  vpc_id               = module.network.vpc_id
  subnet_ids           = [for az in var.azs : module.network.subnet_ids[az]]
  nlb_sg_id            = module.network.nlb_sg_id
  health_check_path    = "/healthz"
  deregistration_delay = 30
}

module "data" {
  source = "../../modules/data"

  name_prefix = var.name_prefix
}

module "compute" {
  source = "../../modules/compute"

  name_prefix          = var.name_prefix
  instance_type        = var.instance_type
  subnet_a_id          = module.network.subnet_ids[var.azs[0]]
  subnet_b_id          = module.network.subnet_ids[var.azs[1]]
  instance_sg_id       = module.network.instance_sg_id
  target_group_arn     = module.nlb.target_group_arn
  table_arn            = module.data.table_arn
  artifacts_bucket_arn = data.aws_s3_bucket.artifacts.arn
}

module "deploy" {
  source = "../../modules/deploy"

  name_prefix       = var.name_prefix
  asg_names         = [module.compute.asg_a_name, module.compute.asg_b_name]
  instance_role_arn = module.compute.instance_role_arn
}
