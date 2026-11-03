# FortiGate-VM FGCP active-passive pair, one node per zone, no public IP.
#
# Each node boots a fresh volume of the factory FortiOS image and configures
# itself from its cloud-init user data: licence, admin account, platform CLI.
# Scaleway hands the user data of an Instance without public IP over a NoCloud
# CD-ROM, and FortiOS (7.4.5+, 7.6.0+) reads it at the first boot of a disk
# only. So a node is rebuilt, never reconfigured in place. Management is port2,
# behind the PGW bastion; port1, the public NIC, has no address.
#
# The egress leg holds the egress VIP as a /32 and reaches the PGWs as
# on-link gateways: the other egress hosts (PGW bastion, LBs, relay) reach
# the spokes through the hub, and their replies must go back that way too. A
# connected /24 on the egress leg would send those replies out of it, which
# FortiOS drops (reply interface != ingress interface).
#
# Scaleway hypervisors only accept a NIC's own MAC: FGCP runs with a unicast
# heartbeat, which keeps the real NIC MACs (no 00:09:0f virtual MAC). Both
# nodes carry the data VIPs as their hub and egress interface addresses
# (interfaces are not synchronised, vdom-exception); only the primary
# answers. The VIPs are also IPAM reservations on the real NIC MAC of the
# primary, which the VPC router uses for the hub ingress rules (failover.tf).

locals {
  # Ingress rule next hop (hub) and SNAT source to the PGWs (egress).
  data_vips = {
    hub    = cidrhost(var.cidrs.hub, var.firewall.hosts.data)
    egress = cidrhost(var.cidrs.egress, var.firewall.hosts.data)
  }

  fw_peer      = { fw1 = "fw2", fw2 = "fw1" }
  fw_nic_order = ["mgmt", "hub", "sync", "egress"]

  # FortiOS names ports by PCI order: port1 is the public NIC, the private
  # NICs follow in attachment order. fortigate.sh checks every MAC against
  # this mapping once the node is up, before any policy push.
  fw_if = { mgmt = "port2", hub = "port3", sync = "port4", egress = "port5" }

  fw = {
    for k, n in var.firewall.nodes : k => merge(n, {
      ip = {
        mgmt   = cidrhost(var.cidrs.mgmt, var.firewall.hosts[k])
        hub    = cidrhost(var.cidrs.hub, var.firewall.hosts[k])
        sync   = cidrhost(var.cidrs.sync, var.firewall.hosts[k])
        egress = cidrhost(var.cidrs.egress, var.firewall.hosts[k])
      }
    })
  }

  fw_nics = merge([
    for k in keys(local.fw) : {
      for net in local.fw_nic_order : "${k}-${net}" => { node = k, net = net }
    }
  ]...)

  # Never sent to the Internet by the [EGRESS] policy: RFC1918 plus every
  # range of the landing zone and of the customer.
  internal_nets = distinct(concat(
    ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"],
    [var.spoke_supernet], values(var.cidrs), local.vpn_cidrs, local.interlink_cidrs,
  ))

  # The syslog relay of modules/observability, unless the list has it already.
  relay_ip = var.syslog_relay_host == null ? null : cidrhost(var.cidrs.egress, var.syslog_relay_host)
  syslog = concat(var.firewall.syslog, local.relay_ip == null || contains([for l in var.firewall.syslog : l.host], coalesce(local.relay_ip, "-")) ? [] : [
    { host = local.relay_ip, port = 514, transport = "udp" },
  ])

  # Per-node platform CLI (interfaces, routes, HA). Interfaces and static
  # routes are excluded from FGCP sync, so both nodes get this, at creation.
  # No secret in it: it is shown in the plan.
  fw_platform = {
    for k, n in local.fw : k => templatefile("${path.module}/fortigate-platform.conf.tftpl", {
      hostname     = "${var.name}-${k}"
      ifs          = local.fw_if
      mgmt_ip      = n.ip.mgmt
      mgmt_mask    = cidrnetmask(var.cidrs.mgmt)
      mgmt_gateway = scaleway_ipam_ip.mgmt_pgw[local.fw_pgw[k]].address
      hub_vip      = local.data_vips.hub
      hub_mask     = cidrnetmask(var.cidrs.hub)
      egress_vip   = local.data_vips.egress
      egress_cidr  = var.cidrs.egress
      sync_ip      = n.ip.sync
      sync_mask    = cidrnetmask(var.cidrs.sync)
      peer_sync_ip = local.fw[local.fw_peer[k]].ip.sync
      priority     = k == "fw1" ? 200 : 100
      hub_vrouter  = local.hub_vrouter_ip
      hub_routes   = concat([var.spoke_supernet, var.cidrs.egress], local.vpn_cidrs)
      pgw          = local.pgw
      monitors     = var.firewall.gateway_monitors
      ha           = merge(var.firewall.ha, { group_name = var.name })
      system       = var.firewall.system
      syslog       = local.syslog
    })
  }

  # The user data of each node: platform CLI, admin account, licence.
  # Secrets: readable through the Instance API by the project's readers.
  fw_user_data = {
    for k, n in local.fw : k => templatefile("${path.module}/fortigate-user-data.yaml.tftpl", {
      platform       = replace(local.fw_platform[k], "@@HA_PASSWORD@@", random_password.ha.result)
      admin_password = random_password.fw_admin.result
      ssh_keys       = [for key in slice(var.admin_ssh_public_keys, 0, min(3, length(var.admin_ssh_public_keys))) : trimspace(key)]
      license        = n.license_file == null ? null : trimspace(file(n.license_file))
    })
  }
}

resource "random_password" "fw_admin" {
  length      = 32
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
  min_special = 2
  # FortiOS CLI and YAML quoting: no quote, backslash, space or $.
  override_special = "#%+,-.:=@^_~"
}

resource "random_password" "ha" {
  length  = 32
  special = false
}

resource "scaleway_ipam_ip" "fw" {
  for_each = local.fw_nics

  project_id = local.project_id
  address    = local.fw[each.value.node].ip[each.value.net]
  source { private_network_id = scaleway_vpc_private_network.this[each.value.net == "sync" ? "ha" : each.value.net].id }
}

# Data VIPs start on fw1's real NICs; the failover moves them to the primary.
resource "scaleway_ipam_ip" "data_vip" {
  for_each = local.data_vips

  project_id = local.project_id
  address    = each.value
  source { private_network_id = scaleway_vpc_private_network.this[each.key].id }

  custom_resource {
    mac_address = local.fw_nic[each.key]["fw1"].mac_address
    name        = "${var.name}-fw1"
  }

  lifecycle {
    # Owned by the failover after creation: never move a VIP back to fw1.
    ignore_changes = [custom_resource]
  }

  # The provider detaches from the MAC in the state; after a failover the
  # API refuses that (412). Move the VIP back to it first.
  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      id=${split("/", self.id)[1]} region=${split("/", self.id)[0]} to=${lower(self.custom_resource[0].mac_address)}
      cur=$(scw ipam ip get $id region=$region -o template='{{ .Resource.MacAddress }}' | tr 'A-F' 'a-f')
      [ "$cur" = "$to" ] || scw ipam ip move $id from-resource.mac-address=$cur to-resource.mac-address=$to region=$region >/dev/null
    EOT
  }
}

# Rebuilding a node = replacing its generation (server, volume).
#   terraform apply -replace='terraform_data.fw_generation["fw1"]'
resource "terraform_data" "fw_generation" {
  for_each = local.fw
  input    = coalesce(each.value.snapshot_id, each.value.image)
}

# What each node reads at first boot: the platform CLI in clear, the user
# data (licence, admin keys, passwords) as a hash. FortiOS reads it once: a
# change shows here and reaches the node when it is rebuilt.
resource "terraform_data" "fw_config" {
  for_each = local.fw
  input = {
    platform  = local.fw_platform[each.key]
    user_data = nonsensitive(sha256(local.fw_user_data[each.key]))
  }
}

resource "scaleway_block_volume" "fw" {
  for_each = { for k, n in local.fw : k => n if n.snapshot_id != null }

  name        = "${var.name}-${each.key}"
  project_id  = local.project_id
  zone        = each.value.zone
  snapshot_id = each.value.snapshot_id
  iops        = var.firewall.disk.iops
  size_in_gb  = var.firewall.disk.size_gb
  tags        = var.tags

  lifecycle {
    replace_triggered_by = [terraform_data.fw_generation[each.key]]
  }
}

# Hypervisor filter on the management NIC: SSH and HTTPS from the PGW
# bastions only. Also set on the unused public NIC: an Instance without a
# security group gets the project default one, created on the fly, which
# then blocks the deletion of the project. The hub, egress and heartbeat
# NICs carry none: their traffic is the firewall's to filter, and a stateful
# hypervisor table on every transit flow or on the heartbeat would add risk
# for no gain.
resource "scaleway_instance_security_group" "fw" {
  for_each = toset(distinct([for n in values(local.fw) : n.zone]))

  name                    = "${var.name}-fw"
  project_id              = local.project_id
  zone                    = each.value
  stateful                = true
  inbound_default_policy  = "drop"
  outbound_default_policy = "accept"
  tags                    = var.tags

  # The PGW bastions, and admin_cidrs with admin_direct_access: the PAT rules
  # keep the client address and have no source filter of their own.
  dynamic "inbound_rule" {
    for_each = setproduct(concat([for p in values(var.egress.pgw_hosts) : "${cidrhost(var.cidrs.mgmt, p)}/32"], var.admin_direct_access ? var.admin_cidrs : []), [22, 443])
    content {
      action   = "accept"
      protocol = "TCP"
      ip_range = inbound_rule.value[0]
      port     = inbound_rule.value[1]
    }
  }
}

resource "scaleway_instance_server" "fw" {
  for_each = local.fw

  name       = "${var.name}-${each.key}"
  project_id = local.project_id
  type       = var.firewall.instance_type
  zone       = each.value.zone
  image      = each.value.image
  boot_type  = each.value.image == null ? "local" : null
  tags       = var.tags

  security_group_id = scaleway_instance_security_group.fw[each.value.zone].id
  user_data         = { "cloud-init" = local.fw_user_data[each.key] }
  # Created stopped: the first boot waits for the private NICs, so FortiOS
  # finds all its ports, which its user data configures, at once (fw_ready
  # starts it).
  state = "stopped"

  dynamic "root_volume" {
    for_each = each.value.image == null ? [scaleway_block_volume.fw[each.key].id] : []
    content {
      volume_id             = root_volume.value
      volume_type           = "sbs_volume"
      size_in_gb            = var.firewall.disk.size_gb
      sbs_iops              = var.firewall.disk.iops
      boot                  = false
      delete_on_termination = false
    }
  }

  lifecycle {
    # type: changing it would stop both nodes; it applies to a rebuilt node.
    # state: started by fw_ready. user_data: erased by fw_ready (fw_config
    # tracks it).
    ignore_changes       = [type, state, user_data]
    replace_triggered_by = [terraform_data.fw_generation[each.key]]
  }
}

resource "scaleway_instance_private_nic" "mgmt" {
  for_each = local.fw

  server_id          = scaleway_instance_server.fw[each.key].id
  private_network_id = scaleway_vpc_private_network.this["mgmt"].id
  ipam_ip_ids        = [scaleway_ipam_ip.fw["${each.key}-mgmt"].id]
  security_group_id  = scaleway_instance_security_group.fw[each.value.zone].id
  zone               = each.value.zone
}

resource "scaleway_instance_private_nic" "hub" {
  for_each = local.fw

  server_id          = scaleway_instance_server.fw[each.key].id
  private_network_id = scaleway_vpc_private_network.this["hub"].id
  ipam_ip_ids        = [scaleway_ipam_ip.fw["${each.key}-hub"].id]
  zone               = each.value.zone
  depends_on         = [scaleway_instance_private_nic.mgmt]
}

resource "scaleway_instance_private_nic" "sync" {
  for_each = local.fw

  server_id          = scaleway_instance_server.fw[each.key].id
  private_network_id = scaleway_vpc_private_network.this["ha"].id
  ipam_ip_ids        = [scaleway_ipam_ip.fw["${each.key}-sync"].id]
  zone               = each.value.zone
  depends_on         = [scaleway_instance_private_nic.hub]
}

resource "scaleway_instance_private_nic" "egress" {
  for_each = local.fw

  server_id          = scaleway_instance_server.fw[each.key].id
  private_network_id = scaleway_vpc_private_network.this["egress"].id
  ipam_ip_ids        = [scaleway_ipam_ip.fw["${each.key}-egress"].id]
  zone               = each.value.zone
  depends_on         = [scaleway_instance_private_nic.sync]
}

locals {
  fw_nic = {
    mgmt   = scaleway_instance_private_nic.mgmt
    hub    = scaleway_instance_private_nic.hub
    sync   = scaleway_instance_private_nic.sync
    egress = scaleway_instance_private_nic.egress
  }
}

# The server first starts here, once its private NICs exist: FortiOS loads
# the licence from its user data, reboots, then applies the CLI. fortigate.sh
# then waits for the admin key to be accepted and the licence to be valid,
# and checks the port <-> MAC mapping. The user data, which FortiOS never
# reads again, are then erased: they hold the licence and the passwords.
# Runs when a node is (re)created.
# Needs scw and ssh on the runner, and the runner in admin_cidrs (bastion).
resource "terraform_data" "fw_ready" {
  for_each = local.fw

  triggers_replace = [scaleway_instance_server.fw[each.key].id]

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      id=${split("/", scaleway_instance_server.fw[each.key].id)[1]} zone=${each.value.zone}
      [ "$(scw instance server get $id zone=$zone -o template='{{.State}}')" = running ] || scw instance server start $id zone=$zone --wait
      ${path.module}/fortigate.sh ready
      scw instance user-data delete server-id=$id key=cloud-init zone=$zone
    EOT
    environment = {
      FGT_HOST     = each.value.ip.mgmt
      FGT_JUMP     = local.bastion[each.key]
      FGT_LICENSED = each.value.license_file == null ? "0" : "1"
      FGT_MACS     = join(" ", [for net in local.fw_nic_order : "${local.fw_if[net]}=${lower(local.fw_nic[net][each.key].mac_address)}"])
    }
  }

  depends_on = [scaleway_instance_private_nic.egress]
}
