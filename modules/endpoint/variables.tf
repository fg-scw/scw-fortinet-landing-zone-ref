variable "name" {
  description = "Endpoint name, used as resource prefix."
  type        = string
}

variable "project_id" {
  type = string
}

variable "private_network_id" {
  description = "Private Network the Load Balancers attach to (backends are reached from there, peered VPCs included)."
  type        = string
}

variable "tags" {
  type    = list(string)
  default = []
}

variable "config" {
  description = "Public endpoint: one Load Balancer per zone, optionally fronted by Edge Services (TLS + WAF)."
  type = object({
    zones         = optional(list(string), ["fr-par-1", "fr-par-2"])
    lb_type       = optional(string, "LB-S")
    frontend_port = optional(number, 80)
    backend = object({
      server_ips       = list(string)
      port             = number
      protocol         = optional(string, "http")
      health_check_uri = optional(string) # HTTP health check; TCP when null
    })
    # Edge Services: managed TLS certificate and WAF in front of the LBs.
    # The LBs then only accept Edge Services IPs.
    edge = optional(object({
      fqdns          = list(string)
      waf_mode       = optional(string, "enable")
      paranoia_level = optional(number, 1)
    }))
  })

  validation {
    condition     = length(var.config.zones) > 0 && length(var.config.backend.server_ips) > 0
    error_message = "An endpoint needs at least one zone and one backend IP."
  }

  validation {
    condition     = contains(["http", "tcp"], var.config.backend.protocol)
    error_message = "backend.protocol must be http or tcp."
  }

  validation {
    condition     = var.config.edge == null || try(length(var.config.edge.fqdns) > 0 && contains(["disable", "log_only", "enable"], var.config.edge.waf_mode), false)
    error_message = "edge needs at least one FQDN and waf_mode disable, log_only or enable."
  }
}
