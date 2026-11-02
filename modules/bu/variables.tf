variable "name" {
  description = "BU key in the registry; also the project and resource name suffix."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,23}$", var.name))
    error_message = "name must be 2-24 lowercase letters, digits or hyphens, starting with a letter."
  }
}

variable "registry" {
  description = "Full BU registry (bus.yaml). Each BU owns a unique, stable index that sets its CIDRs."
  type = map(object({
    index         = number
    hybrid_bypass = optional(bool, false)
    # Baseline security groups accept traffic inside each Private Network;
    # false closes it (workloads then need their own groups to talk).
    intra_pn = optional(bool, true)
    # Edge Services subscription of the BU project (e.g. starter), null = none.
    edge_services_plan = optional(string)
    # Flows allowed INTO the BU from outside it (on-prem, DSI, other BUs once
    # the firewall allows them). The BU NACL drops everything else, except the
    # stateless return range (TCP/UDP 32768-65535 from anywhere, nacl.tf).
    nacl_inbound = optional(list(object({
      to          = string # pub | private
      source      = string
      protocol    = optional(string, "TCP") # ANY | TCP | UDP | ICMP
      port        = optional(number, 0)     # 0 = all ports
      port_end    = optional(number)        # range end, defaults to port
      description = optional(string, "")
    })), [])
  }))

  validation {
    condition = alltrue(flatten([for bu in values(var.registry) : [
      for r in bu.nacl_inbound : contains(["pub", "private"], r.to) && contains(["ANY", "TCP", "UDP", "ICMP"], r.protocol) && can(cidrhost(r.source, 0))
    ]]))
    error_message = "bus.yaml: nacl_inbound needs to = pub|private, protocol = ANY|TCP|UDP|ICMP and a CIDR source."
  }

  validation {
    condition     = contains(keys(var.registry), var.name)
    error_message = "BU ${var.name} is missing from bus.yaml."
  }

  validation {
    condition     = length(distinct([for bu in values(var.registry) : bu.index])) == length(var.registry)
    error_message = "bus.yaml: each BU needs a unique index."
  }

  validation {
    condition     = alltrue([for bu in values(var.registry) : bu.index >= 0 && bu.index < 1024 && floor(bu.index) == bu.index])
    error_message = "bus.yaml: index must be an integer between 0 and 1023."
  }
}

variable "dsi" {
  description = "DSI outputs consumed by the BU (from the dsi unit)."
  type = object({
    hub_vpc_id      = string
    hybrid_vpc_id   = string
    bu_pools        = object({ pub = string, private = string })
    interlink_cidrs = list(string)
    zones           = list(string)
  })
}

variable "iam_permission_sets" {
  description = "Permission sets granted to the BU group on its project. No VPC, gateway, VPN or Interlink rights: network stays under DSI control."
  type        = list(string)
  default = [
    "InstancesFullAccess",
    "BlockStorageFullAccess",
    "LoadBalancersFullAccess",
    "EdgeServicesFullAccess",
    "KubernetesFullAccess",
    "RelationalDatabasesFullAccess",
    "ObjectStorageFullAccess",
    "SecretManagerFullAccess",
    "ObservabilityFullAccess",
    "IPAMFullAccess",
    "PrivateNetworksReadOnly",
    "VPCReadOnly",
  ]
  nullable = false
}
