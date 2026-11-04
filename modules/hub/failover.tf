# The VPC router takes the hub VIP's next hop from the last write: the Gratuitous ARP
# from FGCP, or the IPAM write of the failover container. The new primary calls that
# container on the hub Private Network (automation stitch). Its IAM key is limited to
# IPAM in this project, and the firewall holds only a key that can call it.
# No Internet or Public Gateway is on this path.

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
  description        = "${var.name} firewall failover container"
}

resource "scaleway_container_namespace" "this" {
  name       = "${var.name}-failover"
  project_id = local.project_id
  tags       = var.tags
}

# Stock Python image running the stdlib-only handler: nothing to build or push.
# The firewall calls the private endpoint over its hub leg.
resource "scaleway_container" "ipam_follow" {
  name                           = "ipam-follow"
  namespace_id                   = scaleway_container_namespace.this.id
  image                          = "docker.io/library/python:3.13-slim"
  command                        = ["python", "-c", file("${path.module}/ipam_follow/handler.py")]
  port                           = 8080
  privacy                        = "private"
  private_network_id             = scaleway_vpc_private_network.this["hub"].id
  enable_private_endpoint        = true
  enable_default_public_endpoint = false
  min_scale                      = 1 # a cold start would add to the failover time
  max_scale                      = 1 # one instance: the handler keeps the newest event time in memory
  timeout                        = 60
  tags                           = var.tags

  environment_variables = {
    REGION           = scaleway_container_namespace.this.region
    NODES            = jsonencode(local.ipam_follow_nodes)
    PYTHONUNBUFFERED = "1"
  }
  secret_environment_variables = {
    SCW_SECRET_KEY = scaleway_iam_api_key.ipam_follow.secret_key
  }
}

# Called by IP over TLS, without a host check: FortiOS cannot resolve .internal names,
# and its webhook check also requires the host name to match. Only the firewalls and
# this container sit on the hub PN, and Scaleway drops forged source MACs.
data "scaleway_ipam_ip" "ipam_follow" {
  private_network_id = scaleway_vpc_private_network.this["hub"].id
  type               = "ipv4"
  resource {
    id   = element(split("/", scaleway_container.ipam_follow.id), 1)
    type = "serverless_container"
  }
}

# The firewall's IAM key can only call the private containers of this project.
resource "scaleway_iam_application" "fw_invoke" {
  name        = "${var.name}-fw-invoke"
  description = "FortiGate automation stitch: calls the failover container"
  tags        = var.tags
}

resource "scaleway_iam_policy" "fw_invoke" {
  name           = "${var.name}-fw-invoke"
  application_id = scaleway_iam_application.fw_invoke.id
  tags           = var.tags

  rule {
    project_ids          = [local.project_id]
    permission_set_names = ["ContainersPrivateAccess"]
  }
}

resource "scaleway_iam_api_key" "fw_invoke" {
  application_id     = scaleway_iam_application.fw_invoke.id
  default_project_id = local.project_id
  description        = "${var.name} FortiGate automation stitch"
}
