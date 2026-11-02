output "lb_public_ips" {
  value = { for z, lb in scaleway_lb.this : z => lb.ip_address }
}

output "edge_cname_target" {
  description = "Point every FQDN to this name (CNAME) once Edge Services is enabled."
  value       = local.edge ? scaleway_edge_services_dns_stage.this[0].default_fqdn : null
}
