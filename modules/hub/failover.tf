# The data VIPs follow the FGCP primary in IPAM (the VPC router uses the
# IPAM MAC of the hub VIP, never a gratuitous ARP). The node that becomes
# primary calls a private Serverless Container on the hub Private Network
# (automation stitch, pushed with the policy), which moves both VIPs to its
# NICs with an IAM key limited to IPAM in this project. The firewall only
# holds a key that can call it. Nothing in the failover path crosses the
# Internet or the Public Gateways.

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

# Stock Python image, the stdlib-only handler passed as the command: no
# registry to feed. The firewall calls the private endpoint, through its hub
# leg, and the public endpoint is off.
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
  min_scale                      = 1 # a cold start costs as much as the whole failover
  max_scale                      = 2
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

# Address of the private endpoint. FortiOS refuses to resolve .internal names
# and its webhook checks the certificate name with the chain, so the stitch
# calls this address over TLS without a host check. The hub PN only carries
# the firewalls and the container, and Scaleway drops forged source MACs.
data "scaleway_ipam_ip" "ipam_follow" {
  private_network_id = scaleway_vpc_private_network.this["hub"].id
  type               = "ipv4"
  resource {
    id   = element(split("/", scaleway_container.ipam_follow.id), 1)
    type = "serverless_container"
  }
}

# The firewall authenticates with an IAM key that can only call the private
# containers of this project.
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
