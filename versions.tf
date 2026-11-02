terraform {
  required_version = ">= 1.10"

  required_providers {
    scaleway = {
      source  = "scaleway/scaleway"
      version = "~> 2.89"
    }
  }

  # State in Scaleway Object Storage: bucket, key, region and endpoint come from
  # backend.hcl (terraform init -backend-config=backend.hcl). The state holds
  # the firewall passwords, licences and API keys: keep the bucket private.
  backend "s3" {
    use_lockfile                = true
    skip_region_validation      = true
    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
  }
}

provider "scaleway" {
  region = var.region
  zone   = var.zone
}
