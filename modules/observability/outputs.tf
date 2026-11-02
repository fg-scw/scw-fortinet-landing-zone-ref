output "syslog_target" {
  description = "To copy into firewall.syslog of the DSI, then rebuild the nodes one at a time."
  value       = { host = local.ip, port = 514, transport = "udp" }
}

output "grafana_url" {
  description = "Grafana of the DSI project's Cockpit (Explore, select the logs source)."
  value       = data.scaleway_cockpit_grafana.this.grafana_url
}

output "access" {
  description = "Admin SSH through the Public Gateway bastion."
  value       = "ssh -J ${coalesce(var.bastion, "bastion@<pgw-public-ip>:<port>")} root@${local.ip}"
}
