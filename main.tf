locals {
  # Optional policy (policy.yaml.example). Absent or fully commented means none.
  # yamldecode fails on an empty document, hence the content check; syntax errors still fail the plan.
  policy_raw = fileexists(var.policy_file) ? file(var.policy_file) : ""
  policy     = yamldecode(length(regexall("(?m)^\\s*[^#\\s]", local.policy_raw)) > 0 ? local.policy_raw : "{}")

  # Host number of the syslog relay in the egress network.
  relay_host = 5
}

module "hub" {
  source = "./modules/hub"

  policy                = local.policy
  admin_cidrs           = var.admin_cidrs
  admin_direct_access   = var.admin_direct_access
  admin_ssh_public_keys = var.admin_ssh_public_keys
  firewall              = var.firewall
  edge_services_plan    = var.edge_services_plan
  vpn                   = var.vpn
  interlink             = var.interlink
  syslog_relay_host     = var.observability ? local.relay_host : null
  endpoint_backends = {
    for k, e in var.endpoints : k => { server_ips = e.config.backend.server_ips, port = e.config.backend.port } if e.owner == "hub"
  }
}

module "spoke" {
  source   = "./modules/spoke"
  for_each = var.spokes

  name     = each.key
  registry = var.spokes
  hub      = module.hub.spoke_contract
}

locals {
  endpoint_targets = merge(
    { hub = module.hub.endpoint_target },
    { for k, s in module.spoke : k => s.endpoint_target },
  )
}

module "endpoint" {
  source   = "./modules/endpoint"
  for_each = var.endpoints

  name               = "${each.value.owner}-${each.key}"
  project_id         = local.endpoint_targets[each.value.owner].project_id
  private_network_id = local.endpoint_targets[each.value.owner].private_network_id
  tags               = concat(local.endpoint_targets[each.value.owner].tags, ["endpoint:${each.key}"])
  config             = each.value.config
}

# Syslog relay (firewalls -> Alloy -> Cockpit). Disable it with a customer SIEM,
# and set that collector in firewall.syslog instead.
module "observability" {
  source = "./modules/observability"
  count  = var.observability ? 1 : 0

  name                  = module.hub.observability_target.name
  project_id            = module.hub.observability_target.project_id
  private_network_id    = module.hub.observability_target.private_network_id
  zone                  = module.hub.observability_target.zone
  egress_cidr           = module.hub.observability_target.egress_cidr
  hub_cidr              = module.hub.observability_target.hub_cidr
  pgw_hosts             = module.hub.observability_target.pgw_hosts
  reserved_hosts        = module.hub.observability_target.reserved_hosts
  host                  = local.relay_host
  bastion               = module.hub.observability_target.bastion
  tags                  = concat(module.hub.observability_target.tags, ["observability"])
  admin_ssh_public_keys = var.admin_ssh_public_keys
}
