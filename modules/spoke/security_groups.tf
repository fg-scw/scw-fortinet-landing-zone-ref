# Baseline security groups, one per tier and zone, for the spoke workloads to set
# on their Private Network interfaces (output security_group_ids). Stateful
# and enforced by the hypervisor, they add what the stateless NACLs cannot:
# no service on an ephemeral port is reachable from outside the spoke, and the
# Private Network itself can be closed (intra_pn: false). Sources come from
# var.spokes, like the NACLs. Anyone with InstancesFullAccess on the
# project can edit or detach them: the NACLs stay the guardrail. Instances only:
# Kapsule nodes, Load Balancers and managed databases rely on the NACLs.
# A security group on a private NIC also disables IPv6 autoconfiguration on
# it (the landing zone is IPv4).

locals {
  sg_inbound = {
    pub = concat(
      local.spoke.intra_pn ? [{ protocol = "ANY", source = local.pub_cidr, port = 0, port_end = 0 }] : [],
      local.nacl_inbound.pub,
    )
    private = concat(
      local.spoke.intra_pn ? [{ protocol = "ANY", source = local.private_cidr, port = 0, port_end = 0 }] : [],
      [{ protocol = "ANY", source = local.pub_cidr, port = 0, port_end = 0 }],
      [for cidr in(local.bypass ? var.hub.interlink_cidrs : []) : { protocol = "ANY", source = cidr, port = 0, port_end = 0 }],
      local.nacl_inbound.private,
    )
  }

  sg = {
    for p in setproduct(["pub", "private"], var.hub.zones) : "${p[0]}-${p[1]}" => { tier = p[0], zone = p[1] }
  }
}

resource "scaleway_instance_security_group" "baseline" {
  for_each = local.sg

  name                    = "${local.prefix}-${each.value.tier}"
  description             = "Baseline for ${each.value.tier} Private Network interfaces (var.spokes)"
  project_id              = var.hub.project_id
  zone                    = each.value.zone
  stateful                = true
  inbound_default_policy  = "drop"
  outbound_default_policy = "accept"
  tags                    = local.tags

  # As the NACLs: ICMP from anywhere (path MTU discovery, diagnostics).
  inbound_rule {
    action   = "accept"
    protocol = "ICMP"
    ip_range = "0.0.0.0/0"
  }

  dynamic "inbound_rule" {
    for_each = local.sg_inbound[each.value.tier]
    content {
      action     = "accept"
      protocol   = inbound_rule.value.protocol
      ip_range   = inbound_rule.value.source
      port       = inbound_rule.value.port != 0 && inbound_rule.value.port_end == inbound_rule.value.port ? inbound_rule.value.port : null
      port_range = inbound_rule.value.port != 0 && inbound_rule.value.port_end != inbound_rule.value.port ? "${inbound_rule.value.port}-${inbound_rule.value.port_end}" : null
    }
  }
}
