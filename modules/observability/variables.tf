variable "name" {
  description = "Resource prefix."
  type        = string
  default     = "hub-obs"
}

variable "project_id" {
  description = "Hub project (Cockpit source, token and relay live there)."
  type        = string
}

variable "zone" {
  description = "Zone of the relay VM."
  type        = string
  default     = "fr-par-1"
}

variable "tags" {
  description = "Tags set on every taggable resource."
  type        = list(string)
  default     = ["landing-zone", "hub", "observability"]
  nullable    = false
}

variable "private_network_id" {
  description = "Egress Private Network of the hub (default route through its Public Gateways: Internet for apt and Cockpit)."
  type        = string
}

variable "egress_cidr" {
  description = "CIDR of the Egress Private Network (must equal the hub var.cidrs.egress)."
  type        = string
  default     = "10.0.4.0/24"
}

variable "hub_cidr" {
  description = "CIDR of the Hub Private Network (must equal the hub var.cidrs.hub). Allowed to send syslog."
  type        = string
  default     = "172.16.0.0/24"
}

variable "host" {
  description = "Host number of the relay in the egress network. Must differ from the Public Gateways (default .2/.3), the data VIP (.10) and the firewalls (.11/.12) of the hub, or from the customer's own values."
  type        = number
  default     = 5

  validation {
    condition     = var.host >= 4 && var.host <= 250 && !contains(concat(var.pgw_hosts, var.reserved_hosts), var.host)
    error_message = "host must be between 4 and 250 and free in the egress network (not a Public Gateway, VIP or firewall host)."
  }
  nullable = false
}

variable "reserved_hosts" {
  description = "Host numbers already used in the egress network (hub output observability_target.reserved_hosts)."
  type        = list(number)
  default     = [2, 3, 9, 10, 11, 12]
}

variable "pgw_hosts" {
  description = "Host numbers of the egress Public Gateways (hub egress.pgw_hosts): the SSH bastion comes from these IPs."
  type        = list(number)
  default     = [2, 3]
}

variable "admin_ssh_public_keys" {
  description = "OpenSSH public keys of the root account."
  type        = list(string)

  validation {
    condition     = length(var.admin_ssh_public_keys) > 0 && alltrue([for k in var.admin_ssh_public_keys : can(regex("^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp(256|384|521)) ", trimspace(k)))])
    error_message = "admin_ssh_public_keys must contain OpenSSH public keys."
  }
}

variable "bastion" {
  description = "SSH jump host (bastion@<pgw public ip>:<port>) shown in the access output; null prints a placeholder."
  type        = string
  default     = null
}

variable "instance_type" {
  description = "Relay instance type."
  type        = string
  default     = "PRO2-XXS"
  nullable    = false
}

variable "disk_size_gb" {
  description = "Root volume size."
  type        = number
  default     = 20
  nullable    = false
}

variable "retention_days" {
  description = "Cockpit retention of the logs (check the allowed range with the scaleway_cockpit_config data source)."
  type        = number
  default     = 31
  nullable    = false
}

variable "alloy_version" {
  description = "apt version of the alloy package (e.g. 1.10.0-1); null installs the latest stable. loki.source.syslog needs the syslog_format argument (recent Alloy)."
  type        = string
  default     = null
}

variable "keep_filterlog" {
  description = "Also ship the firewall packet log (program filterlog): very high volume, dropped by default."
  type        = bool
  default     = false
  nullable    = false
}
