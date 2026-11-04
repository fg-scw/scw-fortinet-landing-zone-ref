output "project_id" {
  value = local.project_id
}

# Consumed by every spoke module.
output "spoke_contract" {
  description = "Everything a spoke needs to attach itself to the hub and the hybrid VPC."
  value = {
    project_id      = local.project_id
    hub_vpc_id      = scaleway_vpc.this["hub"].id
    hybrid_vpc_id   = scaleway_vpc.this["hybrid"].id
    spoke_pools     = local.spoke_pools
    interlink_cidrs = local.interlink_cidrs
    # Zones of the spoke baseline security groups: the firewall zones.
    zones = sort(distinct([for n in values(var.firewall.nodes) : n.zone]))
  }
  # Spoke endpoints use the Edge Services plan of the hub project.
  depends_on = [scaleway_edge_services_plan.this]
}

# Consumed by the hub endpoints (LBs and Edge Services in Egress).
output "endpoint_target" {
  value = {
    project_id         = local.project_id
    private_network_id = scaleway_vpc_private_network.this["egress"].id
    tags               = var.tags
  }
  depends_on = [scaleway_edge_services_plan.this]
}

# Consumed by the optional syslog relay (modules/observability).
output "observability_target" {
  value = {
    name               = "${var.name}-obs"
    project_id         = local.project_id
    private_network_id = scaleway_vpc_private_network.this["egress"].id
    tags               = var.tags
    zone               = local.pgw.a.zone
    egress_cidr        = var.cidrs.egress
    hub_cidr           = var.cidrs.hub
    pgw_hosts          = values(var.egress.pgw_hosts)
    # Host numbers taken in the egress network: PGWs, VIPs, firewalls.
    reserved_hosts = distinct(concat(values(var.egress.pgw_hosts), values(var.firewall.hosts)))
    bastion        = local.bastion.fw1
  }
}

output "firewall" {
  value = {
    data_vips = local.data_vips
    nodes     = { for k, n in local.fw : k => merge(n.ip, { zone = n.zone, id = scaleway_instance_server.fw[k].id }) }
  }
}

output "failover_commands" {
  description = "Manual fallback of the failover container: moves the data VIPs in IPAM to the node of the line, from its peer. Run the line of the FGCP primary."
  value = {
    for k in keys(local.fw) : k => join("; ", [
      for net, ip in scaleway_ipam_ip.data_vip :
      "scw ipam ip move ${split("/", ip.id)[1]} from-resource.mac-address=${local.fw_nic[net][local.fw_peer[k]].mac_address} to-resource.mac-address=${local.fw_nic[net][k].mac_address} to-resource.name=${var.name}-${k} region=${split("/", ip.id)[0]}"
    ])
  }
}

output "egress_public_ips" {
  description = "Internet source IPs of the landing zone (allow-list both)."
  value       = { for k, ip in scaleway_vpc_public_gateway_ip.egress : k => ip.address }
}

output "access" {
  description = "Admin access to each firewall through the PGW bastion of its zone (admin_cidrs only); the WebUI through an SSH tunnel. With admin_direct_access, straight on the PGW public IP too."
  value = {
    for k, n in local.fw : k => merge({
      ssh   = "ssh -J ${local.bastion[k]} admin@${n.ip.mgmt}"
      webui = "ssh -N -L 8443:${n.ip.mgmt}:443 -p ${split(":", local.bastion[k])[1]} ${split(":", local.bastion[k])[0]}  # then https://localhost:8443"
      }, var.admin_direct_access ? {
      direct_ssh   = "ssh -p 2222 admin@${scaleway_vpc_public_gateway_ip.egress[local.fw_pgw[k]].address}"
      direct_webui = "https://${scaleway_vpc_public_gateway_ip.egress[local.fw_pgw[k]].address}:8443"
    } : {})
  }
}

output "vpn" {
  description = "One tunnel per zone: configure both on the customer gateway (BGP picks the live one)."
  value = var.vpn == null ? null : {
    for k, g in local.vpn_gateways : k => {
      zone              = g.zone
      gateway_public_ip = data.scaleway_ipam_ip.vpn_gateway[k].address
      psk_secret_id     = scaleway_s2s_vpn_connection.this[k].secret_id
      bgp               = { scaleway = g.bgp_scaleway, onprem = g.bgp_onprem }
    }
  }
}

output "interlink" {
  description = "Pairing key to give to the partner or the PoP (sensitive: terraform output -json interlink)."
  sensitive   = true
  value = var.interlink == null ? null : {
    pairing_key = scaleway_interlink_link.this[0].pairing_key
    status      = scaleway_interlink_link.this[0].status
  }
}

output "fw_admin_password" {
  description = "Generated FortiGate admin password (SSH, WebUI)."
  value       = random_password.fw_admin.result
  sensitive   = true
}
