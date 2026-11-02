# Shared by every unit: one S3 state per unit, provider from the environment.
# Credentials: SCW_ACCESS_KEY / SCW_SECRET_KEY / SCW_DEFAULT_ORGANIZATION_ID
# (org-wide API key) and AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY for the
# state bucket (Scaleway Object Storage keys). Bucket: TG_STATE_BUCKET.
# Region and zone: TG_REGION (default fr-par) and TG_ZONE (default fr-par-1).

locals {
  region      = get_env("TG_REGION", "fr-par")
  zone        = get_env("TG_ZONE", "fr-par-1")
  modules_dir = "${get_parent_terragrunt_dir()}/../modules"
}

generate "backend" {
  path      = "backend.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    terraform {
      backend "s3" {
        bucket       = "${get_env("TG_STATE_BUCKET")}"
        key          = "landing-zone/${path_relative_to_include()}/terraform.tfstate"
        region       = "${local.region}"
        endpoints    = { s3 = "https://s3.${local.region}.scw.cloud" }
        use_lockfile = true

        skip_region_validation      = true
        skip_credentials_validation = true
        skip_requesting_account_id  = true
        skip_metadata_api_check     = true
        skip_s3_checksum            = true
      }
    }
  EOF
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    provider "scaleway" {
      region = "${local.region}"
      zone   = "${local.zone}"
    }
  EOF
}
