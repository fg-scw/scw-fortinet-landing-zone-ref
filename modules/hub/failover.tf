# The data VIPs follow the FGCP primary in IPAM (the VPC router uses the
# IPAM MAC of the hub VIP, never a gratuitous ARP). The node that becomes
# primary calls a private Serverless Function (automation stitch, pushed
# with the policy), which moves both VIPs to its NICs with an IAM key
# limited to IPAM in this project. The firewall only holds a key that can
# call it.

locals {
  # Hub VIP first: it carries the ingress rules.
  ipam_follow_nodes = {
    for k in keys(local.fw) : "${var.name}-${k}" => [
      for net in ["hub", "egress"] : {
        ip_id = split("/", scaleway_ipam_ip.data_vip[net].id)[1]
        mac   = lower(local.fw_nic[net][k].mac_address)
        name  = "${var.name}-${k}"
      }
    ]
  }
}

resource "scaleway_iam_application" "ipam_follow" {
  name        = "${var.name}-ipam-follow"
  description = "Moves the firewall data VIPs in IPAM (hub project only)"
  tags        = var.tags
}

resource "scaleway_iam_policy" "ipam_follow" {
  name           = "${var.name}-ipam-follow"
  application_id = scaleway_iam_application.ipam_follow.id
  tags           = var.tags

  rule {
    project_ids          = [local.project_id]
    permission_set_names = ["IPAMFullAccess"]
  }
}

resource "scaleway_iam_api_key" "ipam_follow" {
  application_id     = scaleway_iam_application.ipam_follow.id
  default_project_id = local.project_id
  description        = "${var.name} firewall failover function"
}

data "archive_file" "ipam_follow" {
  type        = "zip"
  source_file = "${path.module}/ipam_follow/handler.py"
  output_path = "${path.root}/.terraform/ipam-follow.zip"
}

resource "scaleway_function_namespace" "this" {
  name       = "${var.name}-failover"
  project_id = local.project_id
  tags       = var.tags
}

resource "scaleway_function" "ipam_follow" {
  name         = "ipam-follow"
  namespace_id = scaleway_function_namespace.this.id
  runtime      = "python313"
  handler      = "handler.handle"
  privacy      = "private"
  zip_file     = data.archive_file.ipam_follow.output_path
  zip_hash     = data.archive_file.ipam_follow.output_sha256
  deploy       = true
  min_scale    = 1 # a cold start costs as much as the whole failover
  max_scale    = 2
  memory_limit = 128
  timeout      = 60
  http_option  = "redirected"
  tags         = var.tags

  environment_variables = {
    REGION = scaleway_function_namespace.this.region
    NODES  = jsonencode(local.ipam_follow_nodes)
  }
  secret_environment_variables = {
    SCW_SECRET_KEY = scaleway_iam_api_key.ipam_follow.secret_key
  }
}

# The firewall authenticates with an IAM key that can only call the private
# functions of this project.
resource "scaleway_iam_application" "fw_invoke" {
  name        = "${var.name}-fw-invoke"
  description = "FortiGate automation stitch: calls the failover function"
  tags        = var.tags
}

resource "scaleway_iam_policy" "fw_invoke" {
  name           = "${var.name}-fw-invoke"
  application_id = scaleway_iam_application.fw_invoke.id
  tags           = var.tags

  rule {
    project_ids          = [local.project_id]
    permission_set_names = ["FunctionsPrivateAccess"]
  }
}

resource "scaleway_iam_api_key" "fw_invoke" {
  application_id     = scaleway_iam_application.fw_invoke.id
  default_project_id = local.project_id
  description        = "${var.name} FortiGate automation stitch"
}
