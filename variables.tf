variable "region" {
  description = "Region of the landing zone."
  type        = string
  default     = "fr-par"
}

variable "zone" {
  description = "Default zone of the provider (the firewall zones come from firewall.nodes)."
  type        = string
  default     = "fr-par-1"
}

variable "policy_file" {
  description = "Customer firewall policy (see policy.yaml.example). A missing file means no custom policy."
  type        = string
  default     = "policy.yaml"
}

variable "admin_cidrs" {
  description = "Public IPs allowed on the Public Gateway SSH bastion, the Terraform runner included."
  type        = list(string)
}

variable "admin_direct_access" {
  description = "Also reach each firewall on the public IP of its Public Gateway (SSH 2222, WebUI 8443), from admin_cidrs only."
  type        = bool
  default     = false
}

variable "admin_ssh_public_keys" {
  description = "SSH keys of the firewall admin account and the bastions."
  type        = list(string)
}

variable "firewall" {
  description = "Firewall pair: instance type and, per node, zone, factory snapshot and licence file (see modules/hub)."
  type        = any
}

variable "edge_services_plan" {
  description = "Edge Services subscription of the hub project, required by hub endpoints. null = none."
  type        = string
  default     = null
}

variable "vpn" {
  description = "Inspected on-prem access through Site-to-Site VPN (see modules/hub). null = none."
  type        = any
  default     = null
}

variable "interlink" {
  description = "Uninspected on-prem access through Interlink (see modules/hub). null = none."
  type        = any
  default     = null
}

variable "spokes" {
  description = "Spoke registry: name -> index, hybrid_bypass, edge_services_plan, nacl_inbound, intra_pn (see modules/spoke)."
  type        = any
  default     = {}
}

variable "endpoints" {
  description = "Public endpoints: name -> { owner = \"hub\" or a spoke name, config } (see modules/endpoint)."
  type = map(object({
    owner  = string
    config = any
  }))
  default = {}

  validation {
    condition     = alltrue([for e in values(var.endpoints) : e.owner == "hub" || contains(keys(var.spokes), e.owner)])
    error_message = "endpoints.*.owner must be \"hub\" or a key of spokes."
  }

  validation {
    condition     = alltrue([for e in values(var.endpoints) : (e.owner == "hub" ? var.edge_services_plan : try(var.spokes[e.owner].edge_services_plan, null)) != null])
    error_message = "Endpoints are published through Edge Services: set the edge_services_plan of their owner (hub variable or spoke entry)."
  }
}

variable "observability" {
  description = "Deploy the syslog relay to Cockpit (modules/observability)."
  type        = bool
  default     = false
}
