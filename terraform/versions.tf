terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }

  # Use a remote backend for anything shared, for example:
  # backend "s3" {
  #   bucket       = "my-terraform-state"
  #   key          = "team-vpn/terraform.tfstate"
  #   region       = "eu-west-1"
  #   use_lockfile = true
  # }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = merge({ Service = var.name, Terraform = "true" }, var.tags)
  }
}
