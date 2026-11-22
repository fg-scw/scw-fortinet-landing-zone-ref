# Hub project VPCs: Egress, HA (firewall sync), Hub, Hybrid (Interlink, uninspected) and
# Mgmt (firewall management, reached only through the PGW bastion).

locals {
  spoke_pools = {
    pub     = cidrsubnet(var.spoke_supernet, 2, 0)
    private = cidrsubnet(var.spoke_supernet, 1, 1)
  }

  vpn_cidrs       = var.vpn == null ? [] : var.vpn.onprem_cidrs
  interlink_cidrs = var.interlink == null ? [] : var.interlink.onprem_cidrs

  project_id     = coalesce(var.project_id, one(scaleway_account_project.this[*].id))
  hub_vrouter_ip = var.hub_vrouter_ip

  # One Public Gateway per firewall zone. Both firewalls prefer "a" (fw1 zone), so a
  # failover keeps the same NAT state. "b" takes over only when "a" stops answering
  # (FortiGate link monitor).
  pgw = {
    a = { zone = var.firewall.nodes.fw1.zone, ip = cidrhost(var.cidrs.egress, var.egress.pgw_hosts.a) }
    b = { zone = var.firewall.nodes.fw2.zone, ip = cidrhost(var.cidrs.egress, var.egress.pgw_hosts.b) }
  }

  vpcs = {
    mgmt   = var.cidrs.mgmt
    egress = var.cidrs.egress
    ha     = var.cidrs.sync
    hub    = var.cidrs.hub
    hybrid = var.cidrs.hybrid
  }
}

resource "scaleway_account_project" "this" {
  count = var.project_id == null ? 1 : 0

  name        = var.name
  description = "Landing zone hub: central firewall, egress and hybrid connectivity"
}

resource "scaleway_vpc" "this" {
  for_each = local.vpcs

  name                             = "${var.name}-vpc-${each.key}"
  project_id                       = local.project_id
  enable_routing                   = true
  enable_custom_routes_propagation = true
  tags                             = var.tags
}

resource "scaleway_vpc_private_network" "this" {
  for_each = local.vpcs

  name                             = "${var.name}-pn-${each.key}"
  project_id                       = local.project_id
  vpc_id                           = scaleway_vpc.this[each.key].id
  enable_default_route_propagation = false
  tags                             = var.tags
  ipv4_subnet { subnet = each.value }
}


resource "scaleway_iam_ssh_key" "admin" {
  for_each = toset(var.admin_ssh_public_keys)

  name       = "${var.name}-admin-${substr(sha256(each.value), 0, 8)}"
  project_id = local.project_id
  public_key = trimspace(each.value)
}

resource "scaleway_vpc_public_gateway_ip" "egress" {
  for_each = local.pgw

  project_id = local.project_id
  zone       = each.value.zone
}

resource "scaleway_vpc_public_gateway" "egress" {
  for_each = local.pgw

  name              = "${var.name}-pgw-${each.key}"
  project_id        = local.project_id
  type              = var.egress.gateway_type
  zone              = each.value.zone
  ip_id             = scaleway_vpc_public_gateway_ip.egress[each.key].id
  bastion_enabled   = true
  allowed_ip_ranges = local.admin_sources
  refresh_ssh_keys  = join(",", sort([for k in scaleway_iam_ssh_key.admin : k.id]))
  tags              = var.tags
}

resource "scaleway_ipam_ip" "egress_pgw" {
  for_each = local.pgw

  project_id = local.project_id
  address    = each.value.ip
  source { private_network_id = scaleway_vpc_private_network.this["egress"].id }
}

resource "scaleway_vpc_gateway_network" "egress" {
  for_each = local.pgw

  gateway_id         = scaleway_vpc_public_gateway.egress[each.key].id
  private_network_id = scaleway_vpc_private_network.this["egress"].id
  enable_masquerade  = true
  zone               = each.value.zone

  ipam_config {
    push_default_route = true
    ipam_ip_id         = scaleway_ipam_ip.egress_pgw[each.key].id
  }
}

# The same gateways also serve the management network, as SSH bastion and as the gateway
# of the node in their zone.
resource "scaleway_ipam_ip" "mgmt_pgw" {
  for_each = local.pgw

  project_id = local.project_id
  address    = cidrhost(var.cidrs.mgmt, var.egress.pgw_hosts[each.key])
  source { private_network_id = scaleway_vpc_private_network.this["mgmt"].id }
}

resource "scaleway_vpc_gateway_network" "mgmt" {
  for_each = local.pgw

  gateway_id         = scaleway_vpc_public_gateway.egress[each.key].id
  private_network_id = scaleway_vpc_private_network.this["mgmt"].id
  enable_masquerade  = true
  zone               = each.value.zone

  ipam_config {
    push_default_route = true
    ipam_ip_id         = scaleway_ipam_ip.mgmt_pgw[each.key].id
  }
}

locals {
  fw_pgw = { fw1 = "a", fw2 = "b" }
  # admin_direct_access: public PGW port to node port.
  admin_ports = { 2222 = 22, 8443 = 443 }
  bastion = {
    for k, p in local.fw_pgw : k =>
    "bastion@${scaleway_vpc_public_gateway_ip.egress[p].address}:${scaleway_vpc_public_gateway.egress[p].bastion_port}"
  }
}

# Optional direct admin access: each PGW forwards its public ports to the management IP of
# the node in its zone. The firewall security group filters sources (admin_cidrs).
resource "scaleway_vpc_public_gateway_pat_rule" "admin" {
  for_each = var.admin_direct_access ? { for x in setproduct(keys(local.fw_pgw), keys(local.admin_ports)) : "${x[0]}-${x[1]}" => { fw = x[0], port = x[1] } } : {}

  gateway_id   = scaleway_vpc_public_gateway.egress[local.fw_pgw[each.value.fw]].id
  zone         = local.pgw[local.fw_pgw[each.value.fw]].zone
  public_port  = each.value.port
  private_ip   = local.fw[each.value.fw].ip.mgmt
  private_port = local.admin_ports[each.value.port]
  protocol     = "tcp"

  depends_on = [scaleway_vpc_gateway_network.mgmt]
}

# Edge Services pipelines of the endpoints need a subscription per project.
resource "scaleway_edge_services_plan" "this" {
  count = var.edge_services_plan == null ? 0 : 1

  name       = var.edge_services_plan
  project_id = local.project_id
}


resource "scaleway_vpc_connector" "egress_to_hub" {
  name          = "${var.name}-egress-to-hub"
  vpc_id        = scaleway_vpc.this["egress"].id
  target_vpc_id = scaleway_vpc.this["hub"].id
  tags          = var.tags
}

resource "scaleway_vpc_connector" "hub_to_egress" {
  name          = "${var.name}-hub-to-egress"
  vpc_id        = scaleway_vpc.this["hub"].id
  target_vpc_id = scaleway_vpc.this["egress"].id
  tags          = var.tags
}

resource "scaleway_vpc_route" "egress_to_spokes" {
  vpc_id                   = scaleway_vpc.this["egress"].id
  description              = "${var.name}: spoke supernet -> hub firewall"
  destination              = var.spoke_supernet
  nexthop_vpc_connector_id = scaleway_vpc_connector.egress_to_hub.id
  tags                     = var.tags
}

resource "scaleway_vpc_route" "hub_to_egress" {
  for_each = toset(concat([var.cidrs.egress], local.vpn_cidrs))

  vpc_id                   = scaleway_vpc.this["hub"].id
  description              = "${var.name}: ${each.value} via egress"
  destination              = each.value
  nexthop_vpc_connector_id = scaleway_vpc_connector.hub_to_egress.id
  tags                     = var.tags
}

# Every packet entering the hub from a peer goes to the active firewall. The next hop is the
# hub data VIP, which the Gratuitous ARP or the failover container moves to the FGCP primary,
# so these rules never change. The spoke supernet rule covers future spokes too.
resource "scaleway_vpc_ingress_rule" "to_firewall" {
  for_each = toset(concat([var.spoke_supernet, var.cidrs.egress], local.vpn_cidrs))

  vpc_id                     = scaleway_vpc.this["hub"].id
  source                     = each.value
  nexthop_private_network_id = scaleway_vpc_private_network.this["hub"].id
  nexthop_resource_ip        = scaleway_ipam_ip.data_vip["hub"].address
  description                = "${var.name}: ${each.value} -> active firewall"
  tags                       = var.tags
}
