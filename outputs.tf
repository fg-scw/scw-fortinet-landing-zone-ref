output "access" {
  description = "SSH and WebUI access to the firewalls through the bastions."
  value       = module.hub.access
}

output "fw_admin_password" {
  value     = module.hub.fw_admin_password
  sensitive = true
}

output "failover_commands" {
  description = "Manual VIP move, one line per node: run the line of the FGCP primary."
  value       = module.hub.failover_commands
}

output "egress_public_ips" {
  value = module.hub.egress_public_ips
}

output "vpn" {
  value = module.hub.vpn
}

output "interlink" {
  value     = module.hub.interlink
  sensitive = true
}

output "spokes" {
  description = "Project, CIDRs, Private Networks and security groups of each spoke."
  value = { for k, s in module.spoke : k => {
    project_id          = s.project_id
    cidrs               = s.cidrs
    private_network_ids = s.private_network_ids
    security_group_ids  = s.security_group_ids
    iam_group_id        = s.iam_group_id
  } }
}

output "endpoints" {
  description = "Load Balancer IPs and, with Edge Services, the CNAME target of each endpoint."
  value = { for k, e in module.endpoint : k => {
    lb_public_ips     = e.lb_public_ips
    edge_cname_target = e.edge_cname_target
  } }
}

output "observability" {
  description = "Syslog target to copy into firewall.syslog, Grafana URL and relay access."
  value = one([for o in module.observability : {
    syslog_target = o.syslog_target
    grafana_url   = o.grafana_url
    access        = o.access
  }])
}
