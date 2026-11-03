# Firewall policy as data: addresses, services and policies rendered into
# FortiOS CLI and pushed live to the FGCP primary, which syncs the secondary,
# with the failover automation (failover.tf). Interfaces and routes are
# platform (firewall.tf).

locals {
  rule_defaults = { protocol = "any", port = null, port_end = null, state = "sloppy", destination_not = false, log = true, nat = false }

  # Customer rules (var.policy.rules) go before the default ones: the first
  # matching policy wins, so an exception to the inter-spoke block precedes it.
  # Default deny: the hub reaches a spoke only on the backends of its
  # endpoints, on-prem flows are customer rules.
  default_rules = concat([
    merge(local.rule_defaults, {
      action      = "block", interface = "hub", out = "hub", source = "SPOKE_NETS", destination = "SPOKE_NETS"
      description = "[EW] SRC=SPOKE_NETS DST=SPOKE_NETS ACT=BLOCK (inter-spoke, add explicit exceptions above)"
    }),
    ], [
    for name, b in var.endpoint_backends : merge(local.rule_defaults, {
      action      = "pass", interface = "hub", out = "hub", source = "HUB_EGRESS_NET", destination = "lz-ep-${name}", protocol = "tcp", port = b.port
      description = "[HUB] SRC=HUB_EGRESS_NET DST=${name} TCP/${b.port} ACT=PASS (hub endpoint ${name})"
    })
    ], [
    # SNAT to the egress interface address, i.e. the egress data VIP. Traffic
    # log only with a remote collector: on the node alone it fills the disk.
    merge(local.rule_defaults, {
      action      = "pass", interface = "hub", out = "egress", source = "SPOKE_NETS", destination = "internal_nets", destination_not = true
      description = "[EGRESS] SRC=SPOKE_NETS DST=INTERNET ACT=PASS NAT=EGRESS_DATA_VIP", log = length(local.syslog) > 0, nat = true
    }),
  ])

  # Policy id = position, so a re-push only rewrites what moved (fortigate.sh
  # drops the ids that are gone).
  policy_rules = [
    for i, r in concat([for r in var.policy.rules : merge(local.rule_defaults, r, { out = "any" })], local.default_rules) : merge(r, {
      id      = i + 1
      srcintf = local.fw_if[r.interface]
      dstintf = r.out == "any" ? "any" : local.fw_if[r.out]
      srcaddr = local.fgt_addr[r.source]
      dstaddr = local.fgt_addr[r.destination]
      service = r.protocol == "any" ? "ALL" : r.protocol == "icmp" ? "ALL_ICMP" : r.port == null ? upper(r.protocol) == "TCP" ? "ALL_TCP" : "ALL_UDP" : "lz-${r.protocol}-${r.port}${r.port_end == null ? "" : "-${r.port_end}"}"
    })
  ]

  # Built-in aliases, usable in policy files.
  builtin_aliases = merge({
    SPOKE_NETS     = [var.spoke_supernet]
    HUB_EGRESS_NET = [var.cidrs.egress]
    EGRESS_PGWS    = [for p in values(local.pgw) : "${p.ip}/32"]
    internal_nets  = local.internal_nets
    }, length(local.vpn_cidrs) == 0 ? {} : { ONPREM_VPN = local.vpn_cidrs },
    { for name, b in var.endpoint_backends : "lz-ep-${name}" => [for ip in b.server_ips : "${ip}/32"] },
  )

  fgt_aliases = merge(local.builtin_aliases, var.policy.aliases)

  # Every CIDR becomes an address object; an alias is an address group of them.
  fgt_cidrs = distinct(concat(flatten(values(local.fgt_aliases)), [
    for e in concat([for r in var.policy.rules : r.source], [for r in var.policy.rules : r.destination]) : e if can(cidrnetmask(e))
  ]))

  fgt_addr = merge(
    { any = "all" },
    { for c in local.fgt_cidrs : c => "net-${replace(c, "/", "_")}" },
    { for name in keys(local.fgt_aliases) : name => name },
  )

  fgt_services = distinct([
    for r in local.policy_rules : { name = "lz-${r.protocol}-${r.port}${r.port_end == null ? "" : "-${r.port_end}"}", protocol = r.protocol, range = r.port_end == null ? tostring(r.port) : "${r.port}-${r.port_end}" }
    if r.port != null
  ])

  fw_policy = templatefile("${path.module}/fortigate-policy.conf.tftpl", {
    cidrs    = local.fgt_cidrs
    addr     = local.fgt_addr
    aliases  = local.fgt_aliases
    services = local.fgt_services
    rules    = local.policy_rules

    failover_host = "@@FAILOVER_HOST@@"
  })
}

# Pushed live to the primary on every policy change, and once the nodes are
# ready. A setting made in the WebUI is overwritten by the next push.
resource "terraform_data" "fw_policy" {
  input            = local.fw_policy
  triggers_replace = [local.fw_policy, scaleway_iam_api_key.fw_invoke.id, data.scaleway_ipam_ip.ipam_follow.address, [for r in terraform_data.fw_ready : r.id]]

  provisioner "local-exec" {
    command = "${path.module}/fortigate.sh policy"
    environment = {
      FGT_HOSTS      = join(" ", [for k in keys(local.fw) : "${local.fw[k].ip.mgmt}=${local.bastion[k]}"])
      FGT_CONFIG     = base64encode(replace(replace(self.input, "@@FAILOVER_KEY@@", scaleway_iam_api_key.fw_invoke.secret_key), "@@FAILOVER_HOST@@", data.scaleway_ipam_ip.ipam_follow.address))
      FGT_POLICY_IDS = join(" ", [for r in local.policy_rules : r.id])
    }
  }

  lifecycle {
    precondition {
      condition     = length(var.policy.nat_outbound) == 0
      error_message = "policy.nat_outbound is not supported on FortiGate yet: spoke Internet traffic is SNATed to the egress data VIP by the [EGRESS] policy."
    }
  }
}
