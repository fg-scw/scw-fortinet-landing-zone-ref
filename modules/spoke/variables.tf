variable "name" {
  description = "Spoke key in the registry; also the resource name suffix."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,23}$", var.name))
    error_message = "name must be 2-24 lowercase letters, digits or hyphens, starting with a letter."
  }
}

variable "registry" {
  description = "Full spoke registry (var.spokes). Each spoke owns a unique, stable index that sets its CIDRs."
  type = map(object({
    index         = number
    hybrid_bypass = optional(bool, false)
    # Baseline security groups accept traffic inside each Private Network;
    # false closes it (workloads then need their own groups to talk).
    intra_pn = optional(bool, true)
    # Flows allowed INTO the spoke from outside it (on-prem, hub, other spokes once
    # the firewall allows them). The spoke NACL drops everything else, except the
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
    condition = alltrue(flatten([for spoke in values(var.registry) : [
      for r in spoke.nacl_inbound : contains(["pub", "private"], r.to) && contains(["ANY", "TCP", "UDP", "ICMP"], r.protocol) && can(cidrhost(r.source, 0))
    ]]))
    error_message = "var.spokes: nacl_inbound needs to = pub|private, protocol = ANY|TCP|UDP|ICMP and a CIDR source."
  }

  validation {
    condition     = contains(keys(var.registry), var.name)
    error_message = "Spoke ${var.name} is missing from var.spokes."
  }

  validation {
    condition     = length(distinct([for spoke in values(var.registry) : spoke.index])) == length(var.registry)
    error_message = "var.spokes: each spoke needs a unique index."
  }

  validation {
    condition     = alltrue([for spoke in values(var.registry) : spoke.index >= 0 && spoke.index < 1024 && floor(spoke.index) == spoke.index])
    error_message = "var.spokes: index must be an integer between 0 and 1023."
  }
}

variable "hub" {
  description = "Hub outputs consumed by the spoke (module.hub.spoke_contract)."
  type = object({
    project_id      = string
    hub_vpc_id      = string
    hybrid_vpc_id   = string
    spoke_pools     = object({ pub = string, private = string })
    interlink_cidrs = list(string)
    zones           = list(string)
  })
}
