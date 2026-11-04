# Optional syslog relay: FortiGate -> VM in the egress Private Network -> Grafana Alloy
# -> Scaleway Cockpit (Loki). No HA: when the relay is down, the firewalls keep logs locally.

locals {
  ip      = cidrhost(var.egress_cidr, var.host)
  pgw_ips = [for h in var.pgw_hosts : cidrhost(var.egress_cidr, h)]

  # The provider's push_url may or may not include the Loki path.
  push_url = endswith(scaleway_cockpit_source.logs.push_url, "/loki/api/v1/push") ? scaleway_cockpit_source.logs.push_url : "${scaleway_cockpit_source.logs.push_url}/loki/api/v1/push"

  config_alloy = templatefile("${path.module}/config.alloy.tftpl", {
    ip               = local.ip
    push_url         = local.push_url
    keep_traffic_log = var.keep_traffic_log
  })

  nftables = templatefile("${path.module}/nftables.conf.tftpl", {
    pgw_ips = local.pgw_ips
    senders = [var.egress_cidr, var.hub_cidr]
  })

  # No secret here: anything on the VM can read this key from the metadata.
  cloud_init = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    ssh_keys      = [for k in var.admin_ssh_public_keys : trimspace(k)]
    bootstrap     = file("${path.module}/bootstrap.sh")
    config_alloy  = local.config_alloy
    nftables      = local.nftables
    alloy_version = var.alloy_version == null ? "''" : "'${var.alloy_version}'"
  })
}

resource "scaleway_cockpit_source" "logs" {
  name           = "${var.name}-fortigate"
  project_id     = var.project_id
  type           = "logs"
  retention_days = var.retention_days
}

resource "scaleway_cockpit_token" "relay" {
  name       = "${var.name}-relay"
  project_id = var.project_id

  scopes {
    write_logs = true
  }
}

data "scaleway_cockpit_grafana" "this" {
  project_id = var.project_id
}

# The VM boots without a private NIC, hence without metadata. The cloud-init key is
# set after the NIC, then the VM reboots to read it.

# Cloud-init runs once per instance, so a new content hash recreates the relay.
resource "terraform_data" "generation" {
  input = sha256(local.cloud_init)
}

# Same filter as nftables, enforced by the hypervisor on both NICs. Without a security
# group, an Instance gets the project default one, which blocks project deletion.
resource "scaleway_instance_security_group" "relay" {
  name                    = var.name
  project_id              = var.project_id
  zone                    = var.zone
  stateful                = true
  inbound_default_policy  = "drop"
  outbound_default_policy = "accept"
  tags                    = var.tags

  inbound_rule {
    action   = "accept"
    protocol = "ICMP"
    ip_range = "0.0.0.0/0"
  }

  dynamic "inbound_rule" {
    for_each = local.pgw_ips
    content {
      action   = "accept"
      protocol = "TCP"
      ip_range = "${inbound_rule.value}/32"
      port     = 22
    }
  }

  dynamic "inbound_rule" {
    for_each = setproduct([var.egress_cidr, var.hub_cidr], ["TCP", "UDP"])
    content {
      action   = "accept"
      protocol = inbound_rule.value[1]
      ip_range = inbound_rule.value[0]
      port     = 514
    }
  }
}

resource "scaleway_instance_server" "relay" {
  name              = var.name
  project_id        = var.project_id
  zone              = var.zone
  type              = var.instance_type
  image             = "debian_bookworm"
  enable_dynamic_ip = false
  security_group_id = scaleway_instance_security_group.relay.id
  tags              = var.tags

  root_volume {
    size_in_gb = var.disk_size_gb
  }

  # Read once by the bootstrap, which stores it root-only and deletes the key.
  user_data = {
    lz_secrets = sensitive("COCKPIT_TOKEN='${scaleway_cockpit_token.relay.secret_key}'\n")
  }

  lifecycle {
    ignore_changes       = [user_data]
    replace_triggered_by = [terraform_data.generation]
  }
}

resource "scaleway_ipam_ip" "relay" {
  project_id = var.project_id
  address    = local.ip
  source { private_network_id = var.private_network_id }
}

resource "scaleway_instance_private_nic" "relay" {
  server_id          = scaleway_instance_server.relay.id
  private_network_id = var.private_network_id
  ipam_ip_ids        = [scaleway_ipam_ip.relay.id]
  security_group_id  = scaleway_instance_security_group.relay.id
  zone               = var.zone
}

resource "scaleway_instance_user_data" "cloud_init" {
  server_id = scaleway_instance_server.relay.id
  zone      = var.zone
  key       = "cloud-init"
  value     = local.cloud_init

  depends_on = [scaleway_instance_private_nic.relay]

  # The resource ID embeds the server ID, which the provider updates in place. Without this,
  # a rebuilt relay leaves a stale ID that breaks every later plan ("instance_server ... is not found").
  lifecycle {
    replace_triggered_by = [scaleway_instance_server.relay]
  }
}

resource "terraform_data" "reboot" {
  triggers_replace = [scaleway_instance_server.relay.id, scaleway_instance_user_data.cloud_init.value]

  # Requires the scw CLI on the runner.
  provisioner "local-exec" {
    command = "scw instance server reboot ${split("/", scaleway_instance_server.relay.id)[1]} zone=${var.zone} --wait"
  }
}
