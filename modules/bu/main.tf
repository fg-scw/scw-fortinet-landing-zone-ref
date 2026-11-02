# One business unit: its own project, a Pub VPC peered to the DSI hub and a
# Private VPC behind it. Every flow leaving the BU is inspected by the central
# firewall; Private may bypass it only towards on-prem over Interlink.
#
#   Private --peering--> Pub (transitive) --peering--> Hub (ingress rule -> hub data VIP)
#   Private --peering--> Hybrid (Interlink, bypass)            [hybrid_bypass]
#
# Network ACLs imposed on both VPCs live in nacl.tf.

locals {
  bu     = var.registry[var.name]
  prefix = "bu-${var.name}"
  tags   = ["landing-zone", "bu:${var.name}"]

  # Fixed slot sizes: /22 Pub and /21 Private per BU, carved from the DSI pools.
  pub_cidr     = cidrsubnet(var.dsi.bu_pools.pub, 22 - tonumber(split("/", var.dsi.bu_pools.pub)[1]), local.bu.index)
  private_cidr = cidrsubnet(var.dsi.bu_pools.private, 21 - tonumber(split("/", var.dsi.bu_pools.private)[1]), local.bu.index)

  bypass = local.bu.hybrid_bypass && length(var.dsi.interlink_cidrs) > 0
}

resource "scaleway_account_project" "this" {
  name        = local.prefix
  description = "Landing zone BU ${var.name}"
}

# --- VPCs -------------------------------------------------------------------

resource "scaleway_vpc" "pub" {
  name                             = "${local.prefix}-vpc-pub"
  project_id                       = scaleway_account_project.this.id
  enable_routing                   = true
  enable_custom_routes_propagation = true
  enable_transitivity              = true # Private reaches the hub through Pub. Immutable.
  tags                             = local.tags
}

resource "scaleway_vpc" "private" {
  name                             = "${local.prefix}-vpc-private"
  project_id                       = scaleway_account_project.this.id
  enable_routing                   = true
  enable_custom_routes_propagation = true
  tags                             = local.tags
}

resource "scaleway_vpc_private_network" "pub" {
  name                             = "${local.prefix}-pn-pub"
  project_id                       = scaleway_account_project.this.id
  vpc_id                           = scaleway_vpc.pub.id
  enable_default_route_propagation = false
  tags                             = local.tags
  ipv4_subnet { subnet = local.pub_cidr }
}

resource "scaleway_vpc_private_network" "private" {
  name                             = "${local.prefix}-pn-private"
  project_id                       = scaleway_account_project.this.id
  vpc_id                           = scaleway_vpc.private.id
  enable_default_route_propagation = false
  tags                             = local.tags
  ipv4_subnet { subnet = local.private_cidr }
}

# --- Peering connectors (one per side) ---------------------------------------

resource "scaleway_vpc_connector" "pub_to_hub" {
  name          = "${local.prefix}-pub-to-hub"
  vpc_id        = scaleway_vpc.pub.id
  target_vpc_id = var.dsi.hub_vpc_id
  tags          = local.tags
}

resource "scaleway_vpc_connector" "hub_to_pub" {
  name          = "hub-to-${local.prefix}-pub"
  vpc_id        = var.dsi.hub_vpc_id
  target_vpc_id = scaleway_vpc.pub.id
  tags          = local.tags
}

resource "scaleway_vpc_connector" "pub_to_private" {
  name          = "${local.prefix}-pub-to-private"
  vpc_id        = scaleway_vpc.pub.id
  target_vpc_id = scaleway_vpc.private.id
  tags          = local.tags
}

resource "scaleway_vpc_connector" "private_to_pub" {
  name          = "${local.prefix}-private-to-pub"
  vpc_id        = scaleway_vpc.private.id
  target_vpc_id = scaleway_vpc.pub.id
  tags          = local.tags
}

resource "scaleway_vpc_connector" "private_to_hybrid" {
  count         = local.bypass ? 1 : 0
  name          = "${local.prefix}-private-to-hybrid"
  vpc_id        = scaleway_vpc.private.id
  target_vpc_id = var.dsi.hybrid_vpc_id
  tags          = local.tags
}

resource "scaleway_vpc_connector" "hybrid_to_private" {
  count         = local.bypass ? 1 : 0
  name          = "hybrid-to-${local.prefix}-private"
  vpc_id        = var.dsi.hybrid_vpc_id
  target_vpc_id = scaleway_vpc.private.id
  tags          = local.tags
}

# --- Routes -----------------------------------------------------------------
# The hub needs no per-BU ingress rule: the DSI rule on the BU supernet already
# sends every BU source to the hub data VIP (active firewall).

resource "scaleway_vpc_route" "pub_default" {
  vpc_id                   = scaleway_vpc.pub.id
  description              = "${local.prefix}: default -> hub firewall"
  destination              = "0.0.0.0/0"
  nexthop_vpc_connector_id = scaleway_vpc_connector.pub_to_hub.id
  tags                     = local.tags
}

resource "scaleway_vpc_route" "pub_to_private" {
  vpc_id                   = scaleway_vpc.pub.id
  description              = "${local.prefix}: private"
  destination              = local.private_cidr
  nexthop_vpc_connector_id = scaleway_vpc_connector.pub_to_private.id
  tags                     = local.tags
}

resource "scaleway_vpc_route" "private_default" {
  vpc_id                   = scaleway_vpc.private.id
  description              = "${local.prefix}: default -> pub -> hub firewall"
  destination              = "0.0.0.0/0"
  nexthop_vpc_connector_id = scaleway_vpc_connector.private_to_pub.id
  tags                     = local.tags
}

resource "scaleway_vpc_route" "hub_return" {
  for_each = { pub = local.pub_cidr, private = local.private_cidr }

  vpc_id                   = var.dsi.hub_vpc_id
  description              = "${local.prefix}: ${each.key} return"
  destination              = each.value
  nexthop_vpc_connector_id = scaleway_vpc_connector.hub_to_pub.id
  tags                     = local.tags
}

resource "scaleway_vpc_route" "private_to_onprem" {
  for_each = local.bypass ? toset(var.dsi.interlink_cidrs) : toset([])

  vpc_id                   = scaleway_vpc.private.id
  description              = "${local.prefix}: on-prem via Interlink (bypass)"
  destination              = each.value
  nexthop_vpc_connector_id = scaleway_vpc_connector.private_to_hybrid[0].id
  tags                     = local.tags
}

resource "scaleway_vpc_route" "hybrid_return" {
  count = local.bypass ? 1 : 0

  vpc_id                   = var.dsi.hybrid_vpc_id
  description              = "${local.prefix}: private return"
  destination              = local.private_cidr
  nexthop_vpc_connector_id = scaleway_vpc_connector.hybrid_to_private[0].id
  tags                     = local.tags
}

# Per-project subscription required by Edge Services pipelines (endpoints).
resource "scaleway_edge_services_plan" "this" {
  count = local.bu.edge_services_plan == null ? 0 : 1

  name       = local.bu.edge_services_plan
  project_id = scaleway_account_project.this.id
}

# --- IAM: BU team manages workloads, never the network -----------------------

resource "scaleway_iam_group" "this" {
  name                = local.prefix
  description         = "BU ${var.name} operators (membership managed outside Terraform)"
  external_membership = true
}

resource "scaleway_iam_policy" "this" {
  name     = local.prefix
  group_id = scaleway_iam_group.this.id

  rule {
    project_ids          = [scaleway_account_project.this.id]
    permission_set_names = var.iam_permission_sets
  }
}
