## ------------------------------------------------------------------------------------
## Provider & Backend
## ------------------------------------------------------------------------------------
terraform {
  required_version                    = ">= 1.1.0"

  required_providers {
    aws = {
        source                        = "hashicorp/aws"
        version                       = "~> 5.12.0" 
    }
  }

  backend "local" { 
    path                              = "DONTDELETE/terraform.tfstate" 
  }
  
  # Uncomment to use S3 as backend. Consider use of DynamoDB as concurrency lock.
  # https://developer.hashicorp.com/terraform/language/settings/backends/configuration
  # backend "s3" {
  #   region                          = "us-east-1"  # No vars allowed
  #   bucket                          = "nf-nvirginia"
  #   key                             = "graham/terraform/terraform.tfstate"
  #   profile                         = "sts"
  #   shared_credentials_file         = "$HOME/.aws/credentials"
  # }
}


provider "aws" {
  region                              = var.aws_region
  profile                             = var.aws_profile
  retry_mode                          = "adaptive"

  default_tags {
    tags = var.default_tags
  }
}


## ------------------------------------------------------------------------------------
## Miscellaneous core resources and data
## ------------------------------------------------------------------------------------
# Generate unique namespace for this deployment (e.g "modern-sheep")
resource "random_pet" "stackname" { 
  length                              = 2
}


data "aws_caller_identity" "current" {} 


## ------------------------------------------------------------------------------------
## Omnibus Locals
## ------------------------------------------------------------------------------------
locals {

  # Housekeeping 
  # ---------------------------------------------------------------------------------------
  tf_prefix                     = "tf-${var.app_name}-${random_pet.stackname.id}"
  global_prefix                 = ( var.flag_use_custom_resource_naming_prefix == true ?
                                    var.custom_resource_naming_prefix :
                                    local.tf_prefix)


  # Networking
  # ---------------------------------------------------------------------------------------
  vpc_id                              = var.flag_create_new_vpc == true ? module.vpc[0].vpc_id : var.vpc_existing_id

  # If creating VPC from scratch, map all subnet CIDRS to corresponding subnet ID
  #  zipmap -- turn 2 lists into a dictionary. https://developer.hashicorp.com/terraform/language/functions/zipmap
  #  merge  -- join  two dictionaries. https://developer.hashicorp.com/terraform/language/functions/merge
  vpc_new_cidr_block_to_id_public     = var.flag_create_new_vpc == true ? zipmap(module.vpc[0].public_subnets_cidr_blocks, module.vpc[0].public_subnets) : {}
  vpc_new_cidr_block_to_id_private    = var.flag_create_new_vpc == true ? zipmap(module.vpc[0].private_subnets_cidr_blocks, module.vpc[0].private_subnets) : {}
  vpc_new_cidr_block_to_id_unified    = var.flag_create_new_vpc == true ? merge(local.vpc_new_cidr_block_to_id_public, local.vpc_new_cidr_block_to_id_private) : {}

  # Regardless of whether we build a new VPC or use existing, assign the subnet CIDRs to a common variable for subsequent subnet ID lookup. 
  #  concat -- join lists of strings. https://developer.hashicorp.com/terraform/language/functions/concat
  subnets_ec2       = var.flag_create_new_vpc == true ? var.vpc_new_ec2_subnets : var.vpc_existing_ec2_subnets
  subnets_batch     = var.flag_create_new_vpc == true ? var.vpc_new_batch_subnets : var.vpc_existing_batch_subnets
  subnets_db        = var.flag_create_new_vpc == true ? var.vpc_new_db_subnets : var.vpc_existing_db_subnets
  subnets_redis     = var.flag_create_new_vpc == true ? var.vpc_new_redis_subnets : var.vpc_existing_redis_subnets

  subnets_all       = concat(local.subnets_ec2, local.subnets_batch, local.subnets_db, local.subnets_redis)

  # If using existing VPC, get subnet IDs by querying datasources with subnet CIDR.
  # If building new VPC, make dictionary from cidr_block and subnet id (two different list outputs from VPC module).
  subnet_ids_ec2    = ( var.flag_create_new_vpc == true ? 
    [ for cidr in local.subnets_ec2 : lookup(local.vpc_new_cidr_block_to_id_unified, cidr)  ] : 
    [ for cidr in local.subnets_ec2 : data.aws_subnet.existing[cidr].id ]
  )

  subnet_ids_batch    = ( var.flag_create_new_vpc == true ? 
    [ for cidr in local.subnets_batch : lookup(local.vpc_new_cidr_block_to_id_unified, cidr) ] : 
    [ for cidr in local.subnets_batch : data.aws_subnet.existing[cidr].id ]
  )

  subnet_ids_db       = ( var.flag_create_new_vpc == true ? 
    [ for cidr in local.subnets_db : lookup(local.vpc_new_cidr_block_to_id_unified, cidr)  ] : 
    [ for cidr in local.subnets_db : data.aws_subnet.existing[cidr].id ]
  )

  subnet_ids_redis    = ( var.flag_create_new_vpc == true ? 
    [ for cidr in local.subnets_redis : lookup(local.vpc_new_cidr_block_to_id_unified, cidr)  ] : 
    [ for cidr in local.subnets_redis : data.aws_subnet.existing[cidr].id ]
  )

  subnet_ids_alb    = ( 
    var.flag_create_load_balancer == true && var.flag_create_new_vpc == true ? 
      [ for cidr in var.vpc_new_alb_subnets : lookup(local.vpc_new_cidr_block_to_id_unified, cidr)  ] : 
    var.flag_create_load_balancer == true && var.flag_use_existing_vpc == false ?
      [ for cidr in var.vpc_existing_alb_subnets : data.aws_subnet.existing[cidr].id ] : []
  )


  # SSM
  # ---------------------------------------------------------------------------------------
  # Load bootstrapped secrets and define target for TF-generated SSM values. Magical - don't know why it works but it does.
  ssm_root                            = "/config/{$var.app_name}"

  tower_secrets                       = jsondecode(data.aws_ssm_parameter.tower_secrets.value)
  tower_secret_keys                   = nonsensitive(toset([for k,v in local.tower_secrets : k ]))

  seqerakit_secrets                   = jsondecode(data.aws_ssm_parameter.seqerakit_secrets.value)
  seqerakit_secret_keys               = nonsensitive(toset([for k,v in local.seqerakit_secrets : k ]))

  groundswell_secrets                 = jsondecode(data.aws_ssm_parameter.groundswell_secrets.value)
  groundswell_secret_keys             = nonsensitive(toset([for k,v in local.groundswell_secrets : k ]))


  # SSH
  # ---------------------------------------------------------------------------------------
  ssh_key_name                        = "ssh_key_for_${local.global_prefix}.pem"


  # DNS
  # ---------------------------------------------------------------------------------------
  # All values here refer to Route53 in same AWS account as Tower instance.
  # If R53 record not generated, will create entry in EC2 hosts file.
  dns_create_alb_record     = var.flag_create_load_balancer == true && var.flag_create_hosts_file_entry == false ? true : false
  dns_create_ec2_record     = var.flag_create_load_balancer == false && var.flag_create_hosts_file_entry == false ? true : false

  dns_zone_id               = (
    var.flag_create_route53_private_zone == true ? aws_route53_zone.private[0].id :
    var.flag_use_existing_route53_public_zone == true ? data.aws_route53_zone.public[0].id :
    var.flag_use_existing_route53_private_zone == true ? data.aws_route53_zone.private[0].id :
    "No_Match_Found"
  )

  dns_instance_ip           = (
    var.flag_make_instance_private == true ? aws_instance.ec2.private_ip : 
    var.flag_make_instance_private_behind_public_alb == true ? aws_instance.ec2.private_ip :
    var.flag_private_tower_without_eice == true ? aws_instance.ec2.private_ip :
    var.flag_make_instance_public == true ? aws_eip.towerhost[0].public_ip :
    "No_Match_Found"
  )

  # If no HTTPS and no load-balancer, use `http` prefix and expose port in URL. Otherwise, use `https` prefix and no port.
  tower_server_url          = (
    var.flag_create_load_balancer == false && var.flag_do_not_use_https == true ? 
      "http://${var.tower_server_url}:${var.tower_server_port}" :
      "https://${var.tower_server_url}"
  )

  tower_base_url            = "${var.tower_server_url}"
  tower_api_endpoint        = "${local.tower_server_url}/api"


  # Security Groups
  # ---------------------------------------------------------------------------------------
  # Always grant egress anywhere & SSH ingress to EC2 instance. 
  # Add additional ingress restrictions depending on whether ALB is created or not.
  ec2_sg_start      = [ 
    module.tower_ec2_egress_sg.security_group_id,
    module.tower_ec2_ssh_sg.security_group_id
  ]

  ec2_sg_final      = ( 
    var.flag_create_load_balancer == true ? 
      concat( local.ec2_sg_start, [module.tower_ec2_alb_sg.security_group_id] ) : 
      concat( local.ec2_sg_start, [module.tower_ec2_direct_sg.security_group_id] )
  )

  ec2_sg_final_raw = join(",", [ for sg in local.ec2_sg_final: jsonencode(sg) ])

  alb_ingress_cidrs = (
    var.flag_make_instance_public == true || var.flag_make_instance_private_behind_public_alb == true ? var.sg_ingress_cidrs : 
      var.flag_make_instance_private == true && var.flag_create_new_vpc == true ? [ var.vpc_new_cidr_range ] :
      var.flag_make_instance_private == true && var.flag_use_existing_vpc == true ? [ data.aws_vpc.preexisting.cidr_block ] :
      var.flag_private_tower_without_eice == true && var.flag_use_existing_vpc == true ? [ data.aws_vpc.preexisting.cidr_block ] :
      # DELETE THIS
      var.flag_private_tower_without_eice == true && var.flag_create_new_vpc == true ? [ data.aws_vpc.preexisting.cidr_block ] :
      [ "No CIDR block found" ] 
  )


  # Database
  # ---------------------------------------------------------------------------------------
  # If creating new RDS, get address from TF. IF using existing RDS, get address from user. 
  populate_external_db = var.flag_create_external_db == true || var.flag_use_existing_external_db == true ? "true" : "false"
  
  tower_db_url         = var.flag_create_external_db == true ? module.rds[0].db_instance_address : var.tower_db_url


  # Redis
  # ---------------------------------------------------------------------------------------
  tower_redis_url      = (
    var.flag_create_external_redis == true ? 
      "redis://${aws_elasticache_cluster.redis[0].cache_nodes[0].address}:${aws_elasticache_cluster.redis[0].cache_nodes[0].port}" : 
      "redis://redis:6379"
  )

  # Docker-Compose
  # ---------------------------------------------------------------------------------------
  docker_compose_file = (
    var.flag_use_custom_docker_compose_file == false && var.flag_use_container_db == true ? "dc_with_db.yml" :
    var.flag_use_custom_docker_compose_file == false && var.flag_use_container_db == false ? "dc_without_db.yml" :
    var.flag_use_custom_docker_compose_file == true ? "dc_custom.yml" : "No_Match_Found"
  )


  # OIDC
  # ---------------------------------------------------------------------------------------
  # If flags are set, populate local with keyword for MICRONAUT_ENVIRONMENTS inclusion. If not, blank string.
  oidc_auth           = var.flag_oidc_use_generic == true || var.flag_oidc_use_google == true ? ",auth-oidc" : ""
  oidc_github         = var.flag_oidc_use_github == true ? ",auth-github" : ""


  # Miscellaneous
  # ---------------------------------------------------------------------------------------
  # These are needed to handle templatefile rendering to Bash echoing to file craziness.
  dollar = "$"
  singlequote = "'"
}