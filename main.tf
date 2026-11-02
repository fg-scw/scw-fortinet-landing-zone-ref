locals {
  # Optional customer policy (see policy.yaml.example). Absent, empty or fully
  # commented: no custom policy. A syntax error must fail the plan, never
  # silently push an empty policy to running firewalls (yamldecode rejects an
  # empty document, hence the content check).
  policy_raw = fileexists("${path.root}/policy.yaml") ? file("${path.root}/policy.yaml") : ""
  policy     = length(regexall("(?m)^\\s*[^#\\s]", local.policy_raw)) > 0 ? yamldecode(local.policy_raw) : {}
}

module "hub" {
  source = "./modules/hub"

  policy                = local.policy
  admin_cidrs           = var.admin_cidrs
  admin_ssh_public_keys = var.admin_ssh_public_keys
  firewall              = var.firewall
  edge_services_plan    = var.edge_services_plan
  vpn                   = var.vpn
  interlink             = var.interlink
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

# Optional syslog relay (firewalls -> Alloy -> Cockpit). Leave it off when the
# customer has its own SIEM: put its collector in firewall.syslog instead.
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
  bastion               = module.hub.observability_target.bastion
  tags                  = concat(module.hub.observability_target.tags, ["observability"])
  admin_ssh_public_keys = var.admin_ssh_public_keys
}
