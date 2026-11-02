variable "name" {
  description = "Hub project name and resource prefix."
  type        = string
  default     = "hub"
  nullable    = false
}

variable "project_id" {
  description = "Existing project to deploy the hub into; null creates a dedicated project named after var.name."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags set on every taggable resource of the hub."
  type        = list(string)
  default     = ["landing-zone", "hub"]
  nullable    = false
}

variable "cidrs" {
  description = "Hub Private Networks. Must not overlap the spoke supernet nor on-prem."
  type = object({
    mgmt   = optional(string, "10.0.6.0/24")
    egress = optional(string, "10.0.4.0/24")
    sync   = optional(string, "10.255.0.0/24")
    hub    = optional(string, "172.16.0.0/24")
    hybrid = optional(string, "10.0.5.0/24")
  })
  default  = {}
  nullable = false
}

variable "spoke_supernet" {
  description = "Range holding every spoke CIDR: first /12 for Pub slots (/22), second /11 for Private slots (/21). One ingress rule and one FW alias cover all spokes."
  type        = string
  default     = "10.64.0.0/10"

  validation {
    condition     = can(cidrhost(var.spoke_supernet, 0)) && tonumber(split("/", var.spoke_supernet)[1]) <= 10
    error_message = "spoke_supernet must be a CIDR of /10 or larger (1024 spoke slots)."
  }

  # No cidrcontains in Terraform: compare the first and last address of each
  # range as integers. Covers the hub networks, the spoke supernet and the
  # on-prem ranges (VPN, Interlink): an overlap breaks routing and peering,
  # and CIDRs cannot be modified afterwards.
  validation {
    condition = try(!anytrue(flatten([
      for ranges in [concat(
        values(var.cidrs), [var.spoke_supernet],
        var.vpn == null ? [] : var.vpn.onprem_cidrs,
        var.interlink == null ? [] : var.interlink.onprem_cidrs,
        )] : [
        for i, a in ranges : [
          for j, b in ranges : i < j &&
          sum([for k, o in split(".", cidrhost(a, 0)) : tonumber(o) * pow(256, 3 - k)]) <= sum([for k, o in split(".", cidrhost(b, -1)) : tonumber(o) * pow(256, 3 - k)]) &&
          sum([for k, o in split(".", cidrhost(b, 0)) : tonumber(o) * pow(256, 3 - k)]) <= sum([for k, o in split(".", cidrhost(a, -1)) : tonumber(o) * pow(256, 3 - k)])
        ]
      ]
    ])), false)
    error_message = "cidrs, spoke_supernet, vpn.onprem_cidrs and interlink.onprem_cidrs must be valid IPv4 CIDRs that do not overlap each other."
  }
  nullable = false
}

variable "hub_vrouter_ip" {
  description = "Next hop of the firewall routes towards the hub VPC router. On Scaleway Private Networks the VPC router answers on 169.254.169.254 (on-link), not on the first host of the subnet."
  type        = string
  default     = "169.254.169.254"
  nullable    = false
}

variable "admin_cidrs" {
  description = "Public CIDRs allowed on the Public Gateway SSH bastion."
  type        = list(string)

  validation {
    condition     = length(var.admin_cidrs) > 0 && alltrue([for c in var.admin_cidrs : can(cidrhost(c, 0)) && c != "0.0.0.0/0"])
    error_message = "admin_cidrs must contain valid, non-default CIDRs."
  }
}

variable "admin_ssh_public_keys" {
  description = "OpenSSH public keys for the bastion and the firewalls' admin account (the first 3 on the firewalls)."
  type        = list(string)

  validation {
    condition     = length(var.admin_ssh_public_keys) > 0 && alltrue([for k in var.admin_ssh_public_keys : can(regex("^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp(256|384|521)) ", trimspace(k)))])
    error_message = "admin_ssh_public_keys must contain OpenSSH public keys."
  }
}

variable "firewall" {
  description = "FortiGate-VM FGCP pair, without public IP. Each node boots from exactly one of: a block snapshot of the factory FortiOS KVM image (a fresh volume is created from it) or an image (label or zone-local ID) of it. Never a disk that has already booted: FortiOS reads its cloud-init user data at first boot only. Node zones must offer Public Gateways, VPN and LB (fr-par-1 and fr-par-2, not fr-par-3)."
  type = object({
    instance_type = optional(string, "POP2-2C-8G")
    disk = optional(object({
      size_gb = optional(number, 10)
      iops    = optional(number, 5000)
    }), {})
    # Host numbers in the mgmt, hub, sync and egress networks (data VIPs,
    # nodes).
    hosts = optional(object({
      data = optional(number, 10) # IPAM data VIPs, hub and egress
      fw1  = optional(number, 11)
      fw2  = optional(number, 12)
    }), {})
    system = optional(object({
      timezone = optional(string, "Europe/Paris")
      dns      = optional(list(string), ["1.1.1.1", "1.0.0.1"])
      ntp      = optional(list(string), ["0.pool.ntp.org", "1.pool.ntp.org"])
    }), {})
    # Link monitor targets, one per Public Gateway.
    gateway_monitors = optional(object({
      a = optional(string, "1.0.0.1")
      b = optional(string, "9.9.9.9")
    }), {})
    # FGCP. arps/arps_interval: gratuitous ARPs sent by a new primary; 60 x 1 s
    # is the setting validated on Scaleway (the default 5 x 5 s loses some).
    ha = optional(object({
      arps          = optional(number, 60)
      arps_interval = optional(number, 1)
    }), {})
    # Remote syslog collectors (UDP or TCP), at most 4. Platform setting:
    # changing it means rebuilding the nodes.
    syslog = optional(list(object({
      host      = string
      port      = optional(number, 514)
      transport = optional(string, "udp")
    })), [])
    nodes = map(object({
      zone        = string
      image       = optional(string)
      snapshot_id = optional(string)
      # FortiGate-VM licence file (.lic) of this node, in its cloud-init user data.
      license_file = optional(string)
    }))
  })

  validation {
    condition     = length(distinct(concat(values(var.firewall.hosts), values(var.egress.pgw_hosts)))) == 5
    error_message = "firewall.hosts must be 3 distinct host numbers, none equal to egress.pgw_hosts."
  }

  validation {
    condition = length(var.firewall.syslog) <= (var.syslog_relay_host == null ? 4 : 3) && alltrue([
      for l in var.firewall.syslog :
      can(regex("^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$", l.host)) && l.port >= 1 && l.port <= 65535 && contains(["udp", "tcp"], l.transport)
    ]) && length(distinct([for l in var.firewall.syslog : "${l.host}:${l.port}"])) == length(var.firewall.syslog)
    error_message = "firewall.syslog: at most 4 entries, the syslog relay included; host is an IPv4 address or a host name, port 1-65535, transport udp|tcp, one entry per host:port."
  }

  validation {
    condition     = length(var.firewall.system.dns) > 0 && length(var.firewall.system.ntp) > 0
    error_message = "firewall.system.dns and firewall.system.ntp need at least one entry."
  }

  validation {
    condition     = var.firewall.ha.arps >= 1 && var.firewall.ha.arps <= 60 && var.firewall.ha.arps_interval >= 1 && var.firewall.ha.arps_interval <= 20
    error_message = "firewall.ha: arps 1-60, arps_interval 1-20 (FortiOS limits)."
  }

  validation {
    condition     = toset(keys(var.firewall.nodes)) == toset(["fw1", "fw2"])
    error_message = "firewall.nodes must define exactly fw1 and fw2."
  }

  validation {
    condition     = alltrue([for n in values(var.firewall.nodes) : length(compact([n.image, n.snapshot_id])) == 1])
    error_message = "Each firewall node needs exactly one of image or snapshot_id."
  }

  validation {
    condition     = alltrue([for n in values(var.firewall.nodes) : n.license_file == null || fileexists(coalesce(n.license_file, "-"))])
    error_message = "firewall.nodes.*.license_file must be an existing file."
  }
}

variable "egress" {
  description = "Egress Public Gateways: type and host number of each one in the egress network."
  type = object({
    gateway_type = optional(string, "VPC-GW-S")
    pgw_hosts = optional(object({
      a = optional(number, 2)
      b = optional(number, 3)
    }), {})
  })
  default  = {}
  nullable = false
}

variable "edge_services_plan" {
  description = "Edge Services subscription of the hub project (e.g. starter), needed by hub endpoints using Edge Services. null = none."
  type        = string
  default     = null
}

variable "vpn" {
  description = "Optional S2S VPN in the Egress VPC, one gateway per firewall zone. On-prem flows through it are inspected by the firewall."
  type = object({
    customer_gateway_ip = string
    customer_asn        = number
    onprem_cidrs        = list(string)
    gateway_type        = optional(string, "VGW-S")
    # IKE (phase 1) and ESP (phase 2) proposals offered to the customer gateway.
    ciphers = optional(object({
      ike = optional(object({
        encryption = optional(string, "aes256")
        integrity  = optional(string, "sha256")
        dh_group   = optional(string, "modp2048")
      }), {})
      esp = optional(object({
        encryption = optional(string, "aes256")
        integrity  = optional(string, "sha256")
        dh_group   = optional(string, "modp2048")
      }), {})
    }), {})
    # BGP /30 of each tunnel (a, b): Scaleway side and on-prem side.
    bgp_links = optional(object({
      a = optional(object({ scaleway = string, onprem = string }), { scaleway = "169.254.100.1/30", onprem = "169.254.100.2/30" })
      b = optional(object({ scaleway = string, onprem = string }), { scaleway = "169.254.100.5/30", onprem = "169.254.100.6/30" })
    }), {})
  })
  default = null

  validation {
    condition     = var.vpn == null || alltrue([for l in values(var.vpn.bgp_links) : alltrue([for c in values(l) : can(cidrhost(c, 0))])])
    error_message = "vpn.bgp_links must hold valid CIDRs (/30)."
  }
}

variable "interlink" {
  description = "Optional Interlink on the Hybrid VPC. spoke Private VPCs with hybrid_bypass reach these on-prem CIDRs without inspection."
  type = object({
    pop_id         = string
    bandwidth_mbps = number
    onprem_cidrs   = list(string)
    partner_id     = optional(string) # hosted link
    connection_id  = optional(string) # self-hosted link
    peer_asn       = optional(number) # self-hosted only
    vlan           = optional(number) # self-hosted only
  })
  default = null

  validation {
    condition     = var.interlink == null || (try(var.interlink.partner_id, null) == null) != (try(var.interlink.connection_id, null) == null)
    error_message = "interlink needs either partner_id (hosted) or connection_id (self-hosted)."
  }
}

variable "policy" {
  description = <<-EOT
    Customer firewall policy, rendered into FortiOS CLI and pushed live to the
    FGCP primary. Rules are evaluated in order, before the default
    [EW] (inter-spoke block), [HUB], [VPN] and [EGRESS] rules.
    - aliases: name => CIDRs, usable as source/destination.
    - rules: source/destination are an alias (built-in: SPOKE_NETS, HUB_EGRESS_NET,
      ONPREM_VPN, EGRESS_PGWS, internal_nets, or yours), a CIDR or "any".
    - nat_outbound: not supported on FortiGate yet (must stay empty).
  EOT
  type = object({
    aliases = optional(map(list(string)), {})
    rules = optional(list(object({
      description = string
      action      = string # pass | block
      interface   = optional(string, "hub")
      source      = string
      destination = string
      protocol    = optional(string, "any")
      port        = optional(number)
      port_end    = optional(number)
      state       = optional(string, "sloppy")
    })), [])
    nat_outbound = optional(list(object({
      description = string
      source      = string
      destination = optional(string, "any")
      target      = optional(string)
    })), [])
  })
  default  = {}
  nullable = false

  # Built-in alias names (policy.tf) are listed here: a
  # variable cannot read locals.
  validation {
    condition = alltrue([
      for e in concat(
        [for r in var.policy.rules : r.source], [for r in var.policy.rules : r.destination],
        [for n in var.policy.nat_outbound : n.source], [for n in var.policy.nat_outbound : n.destination]
        ) : e == "any" || can(cidrhost(e, 0)) || contains(
        concat(["SPOKE_NETS", "HUB_EGRESS_NET", "ONPREM_VPN", "EGRESS_PGWS", "internal_nets"], keys(var.policy.aliases)), e
      )
    ])
    error_message = "policy source/destination must be \"any\", a valid CIDR or an existing alias name."
  }

  validation {
    condition = alltrue([
      for r in var.policy.rules :
      contains(["pass", "block"], r.action) && contains(["hub", "egress"], r.interface) &&
      contains(["any", "tcp", "udp", "icmp"], r.protocol) && contains(["sloppy", "keep"], r.state)
    ])
    error_message = "policy.rules: action pass|block, interface hub|egress, protocol any|tcp|udp|icmp, state sloppy|keep."
  }

  validation {
    condition = alltrue([
      for r in var.policy.rules : r.port == null ? r.port_end == null : (contains(["tcp", "udp"], r.protocol) && r.port >= 1 && r.port <= 65535 && coalesce(r.port_end, r.port) >= r.port && coalesce(r.port_end, r.port) <= 65535)
    ])
    error_message = "policy.rules: port needs protocol tcp or udp, within 1-65535, and port_end >= port."
  }

  # Descriptions go into quoted FortiOS CLI strings: no quote, backslash or
  # markup; unique, as they name the rules.
  validation {
    condition = alltrue([
      for d in concat([for r in var.policy.rules : r.description], [for n in var.policy.nat_outbound : n.description]) :
      length(d) > 0 && !can(regex("[<>&\"\\\\]", d))
    ]) && length(distinct([for r in var.policy.rules : r.description])) == length(var.policy.rules)
    error_message = "policy descriptions must be unique, non-empty and free of <, >, &, \" and \\."
  }

  validation {
    condition = alltrue([for name, cidrs in var.policy.aliases :
      can(regex("^[A-Za-z][A-Za-z0-9_]{0,31}$", name)) && !contains(["SPOKE_NETS", "HUB_EGRESS_NET", "ONPREM_VPN", "EGRESS_PGWS", "internal_nets"], name) &&
      length(cidrs) > 0 && alltrue([for c in cidrs : can(cidrhost(c, 0))])
    ])
    error_message = "policy.aliases: names are letters, digits and _ (32 max), not a built-in alias; values are non-empty lists of valid CIDRs."
  }

  validation {
    condition     = alltrue([for n in var.policy.nat_outbound : n.target == null || can(cidrhost("${n.target}/32", 0))])
    error_message = "policy.nat_outbound target must be an IPv4 address."
  }
}

variable "syslog_relay_host" {
  description = "Host number of the syslog relay (modules/observability) in the egress network: the nodes log to it from their first boot, on top of firewall.syslog. null = no relay."
  type        = number
  default     = null
}
