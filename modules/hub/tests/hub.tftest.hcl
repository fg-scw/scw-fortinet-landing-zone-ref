# terraform test - offline, no Scaleway API call.
mock_provider "scaleway" {
  # The provider validates ID formats, so mocks need realistic IDs.
  mock_resource "scaleway_account_project" {
    defaults = { id = "44444444-4444-4444-4444-444444444444" }
  }
  mock_resource "scaleway_vpc" {
    defaults = { id = "fr-par/44444444-4444-4444-4444-444444444444" }
  }
  mock_resource "scaleway_vpc_private_network" {
    defaults = { id = "fr-par/44444444-4444-4444-4444-444444444444" }
  }
  mock_resource "scaleway_ipam_ip" {
    defaults = { id = "fr-par/44444444-4444-4444-4444-444444444444" }
  }
  mock_resource "scaleway_vpc_connector" {
    defaults = { id = "fr-par/44444444-4444-4444-4444-444444444444" }
  }
  mock_resource "scaleway_s2s_vpn_customer_gateway" {
    defaults = { id = "fr-par/44444444-4444-4444-4444-444444444444" }
  }
  mock_resource "scaleway_s2s_vpn_routing_policy" {
    defaults = { id = "fr-par/44444444-4444-4444-4444-444444444444" }
  }
  mock_resource "scaleway_instance_server" {
    defaults = { id = "fr-par-1/44444444-4444-4444-4444-444444444444" }
  }
  mock_resource "scaleway_block_volume" {
    defaults = { id = "fr-par-1/44444444-4444-4444-4444-444444444444" }
  }
  mock_resource "scaleway_vpc_public_gateway" {
    defaults = { id = "fr-par-1/44444444-4444-4444-4444-444444444444" }
  }
  mock_resource "scaleway_vpc_public_gateway_ip" {
    defaults = { id = "fr-par-1/44444444-4444-4444-4444-444444444444" }
  }
  mock_resource "scaleway_s2s_vpn_gateway" {
    defaults = { id = "fr-par-1/44444444-4444-4444-4444-444444444444" }
  }
  mock_resource "scaleway_container_namespace" {
    defaults = { id = "fr-par/44444444-4444-4444-4444-444444444444" }
  }
  mock_resource "scaleway_container" {
    override_during = plan
    defaults        = { id = "fr-par/44444444-4444-4444-4444-444444444444" }
  }
  mock_resource "scaleway_iam_api_key" {
    override_during = plan
    defaults        = { secret_key = "test-secret-key" }
  }
}


mock_provider "random" {
  override_during = plan
  mock_resource "random_password" {
    defaults = { result = "test-password" }
  }
}

variables {
  admin_cidrs           = ["203.0.113.10/32"]
  admin_ssh_public_keys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest admin"]
  firewall = {
    nodes = {
      fw1 = { zone = "fr-par-1", image = "fortigate" }
      fw2 = { zone = "fr-par-2", image = "fortigate" }
    }
  }
  vpn = {
    customer_gateway_ip = "198.51.100.1"
    customer_asn        = 65010
    onprem_cidrs        = ["192.168.0.0/16"]
  }
}

run "address_plan_and_ingress" {
  command = plan

  assert {
    condition     = output.spoke_contract.spoke_pools.pub == "10.64.0.0/12" && output.spoke_contract.spoke_pools.private == "10.96.0.0/11"
    error_message = "Spoke pools must be carved from the supernet."
  }

  assert {
    condition     = toset(keys(scaleway_vpc_ingress_rule.to_firewall)) == toset(["10.64.0.0/10", "10.0.4.0/24", "192.168.0.0/16"])
    error_message = "Hub ingress rules: spoke supernet, hub egress and VPN on-prem, nothing per spoke."
  }

  assert {
    condition     = alltrue([for r in scaleway_vpc_ingress_rule.to_firewall : r.nexthop_resource_ip == "172.16.0.10"])
    error_message = "Ingress rules must target the hub data VIP."
  }

  assert {
    condition     = scaleway_vpc_public_gateway.egress["a"].zone == "fr-par-1" && scaleway_vpc_public_gateway.egress["b"].zone == "fr-par-2"
    error_message = "One Public Gateway per firewall zone."
  }

  assert {
    condition     = scaleway_s2s_vpn_gateway.this["a"].zone == "fr-par-1" && scaleway_s2s_vpn_gateway.this["b"].zone == "fr-par-2" && scaleway_s2s_vpn_connection.this["b"].bgp_config_ipv4[0].private_ip == "169.254.100.5/30"
    error_message = "One VPN gateway and tunnel per firewall zone, with distinct BGP /30."
  }

  assert {
    condition     = scaleway_ipam_ip.data_vip["hub"].address == "172.16.0.10" && scaleway_ipam_ip.data_vip["egress"].address == "10.0.4.10"
    error_message = "Data VIPs: .10 of the hub and egress networks."
  }
}

# The root module forwards unset options as null: null must mean the default.
run "null_means_default" {
  command = plan

  variables {
    name           = null
    tags           = null
    cidrs          = null
    spoke_supernet = null
    hub_vrouter_ip = null
    egress         = null
  }

  assert {
    condition     = output.spoke_contract.spoke_pools.pub == "10.64.0.0/12" && scaleway_ipam_ip.data_vip["hub"].address == "172.16.0.10" && scaleway_account_project.this[0].name == "hub"
    error_message = "Null options must fall back to the module defaults."
  }
}

run "platform_config" {
  command = plan

  # Both nodes carry the VIPs on their data interfaces (interfaces are not
  # synchronised); only priority, sync IP and peer differ.
  assert {
    condition = alltrue([for k in ["fw1", "fw2"] : alltrue([
      strcontains(terraform_data.fw_config[k].input.platform, "set ip 172.16.0.10 255.255.255.0"),
      strcontains(terraform_data.fw_config[k].input.platform, "set ip 10.0.4.10 255.255.255.255"),
      strcontains(terraform_data.fw_config[k].input.platform, "set object system.interface"),
      strcontains(terraform_data.fw_config[k].input.platform, "set object router.static"),
      strcontains(terraform_data.fw_config[k].input.platform, "set unicast-hb enable"),
      strcontains(terraform_data.fw_config[k].input.platform, "set arps 60"),
      strcontains(terraform_data.fw_config[k].input.platform, "set arps-interval 1"),
      strcontains(terraform_data.fw_config[k].input.platform, "set override disable"),
      strcontains(terraform_data.fw_config[k].input.platform, "set password \"@@HA_PASSWORD@@\""),
    ])])
    error_message = "Platform CLI: hub VIP /24, egress VIP /32, interfaces and routes out of sync, unicast heartbeat, 60 x 1 s GARP, no override, HA password as a token."
  }

  assert {
    condition = alltrue([
      strcontains(terraform_data.fw_config["fw1"].input.platform, "set ip 10.255.0.11 255.255.255.0"),
      strcontains(terraform_data.fw_config["fw1"].input.platform, "set unicast-hb-peerip 10.255.0.12"),
      strcontains(terraform_data.fw_config["fw1"].input.platform, "set priority 200"),
      strcontains(terraform_data.fw_config["fw2"].input.platform, "set ip 10.255.0.12 255.255.255.0"),
      strcontains(terraform_data.fw_config["fw2"].input.platform, "set unicast-hb-peerip 10.255.0.11"),
      strcontains(terraform_data.fw_config["fw2"].input.platform, "set priority 100"),
    ])
    error_message = "Each node has its own sync IP, points at its peer, and fw1 is the preferred primary."
  }

  # Hub routes: spoke supernet and VPN on-prem, via the on-link VPC router.
  assert {
    condition = alltrue([
      can(regex("(?s)set dst 10.64.0.0/10\\s+set gateway 169.254.169.254\\s+set device \"port3\"", terraform_data.fw_config["fw1"].input.platform)),
      can(regex("(?s)set dst 192.168.0.0/16\\s+set gateway 169.254.169.254", terraform_data.fw_config["fw1"].input.platform)),
      can(regex("(?s)set dst 10.0.4.0/24\\s+set gateway 169.254.169.254\\s+set device \"port3\"", terraform_data.fw_config["fw2"].input.platform)),
      can(regex("(?s)set gateway 10.0.4.2\\s+set device \"port5\"\\s+set distance 10", terraform_data.fw_config["fw1"].input.platform)),
      can(regex("(?s)set gateway 10.0.4.3\\s+set device \"port5\"\\s+set distance 20", terraform_data.fw_config["fw2"].input.platform)),
    ])
    error_message = "Hub routes via 169.254.169.254 on port3 (spoke supernet, hub egress, VPN); default via PGW a, then PGW b."
  }
}

run "no_secret_in_rendered_config" {
  command = plan

  assert {
    condition     = alltrue([for k in ["fw1", "fw2"] : !strcontains(terraform_data.fw_config[k].input.platform, "test-password")]) && !strcontains(terraform_data.fw_policy.input, "test-password") && !strcontains(terraform_data.fw_policy.input, "test-secret-key")
    error_message = "Rendered CLI is shown in the plan: no password nor key in it."
  }

  assert {
    condition     = alltrue([for k in ["fw1", "fw2"] : can(regex("^[0-9a-f]{64}$", terraform_data.fw_config[k].input.user_data))])
    error_message = "fw_config tracks the user data (licence, keys, passwords) as a hash only."
  }
}

run "failover_automation" {
  command = plan

  assert {
    condition = alltrue([
      can(regex("(?s)edit \"lz-became-primary\".*?set event-type event-log\\s+set logid 37892.*?set name \"ha_role\"\\s+set value \"primary\"", terraform_data.fw_policy.input)),
      can(regex("(?s)set uri \"@@FAILOVER_HOST@@/\".*?set http-body \"\\{\\\\\"node\\\\\":\\\\\"%%log.devname%%\\\\\"\\}\".*?set value \"@@FAILOVER_KEY@@\"", terraform_data.fw_policy.input)),
      length(regexall("set action \"lz-ipam-follow\"", terraform_data.fw_policy.input)) == 4,
      scaleway_container.ipam_follow.privacy == "private",
      scaleway_container.ipam_follow.enable_default_public_endpoint == false,
      one(scaleway_iam_policy.ipam_follow.rule).permission_set_names == toset(["IPAMFullAccess"]),
      one(scaleway_iam_policy.fw_invoke.rule).permission_set_names == toset(["ContainersPrivateAccess"]),
    ])
    error_message = "Becoming primary calls the private failover container (3 tries + hourly reconcile) with the node hostname; key injected at push time only; least-privilege IAM."
  }
}

run "default_policy" {
  command = plan

  assert {
    condition = alltrue([
      can(regex("(?s)edit 1\\s+set name \"lz-1\"\\s+set comments \"\\[EW\\][^\"]*\"\\s+set srcintf \"port3\"\\s+set dstintf \"port3\"\\s+set srcaddr \"SPOKE_NETS\"\\s+set dstaddr \"SPOKE_NETS\".*?set action deny", terraform_data.fw_policy.input)),
      can(regex("(?s)\\[EGRESS\\][^\"]*\"\\s+set srcintf \"port3\"\\s+set dstintf \"port5\"\\s+set srcaddr \"SPOKE_NETS\"\\s+set dstaddr \"internal_nets\"\\s+set dstaddr-negate enable\\s+set action accept.*?set logtraffic disable\\s+set nat enable", terraform_data.fw_policy.input)),
      !strcontains(terraform_data.fw_policy.input, "[VPN]") && !strcontains(terraform_data.fw_policy.input, "[HUB]"),
      strcontains(terraform_data.fw_policy.input, "set tcp-session-without-syn all"),
    ])
    error_message = "Default deny: inter-spoke block, then Internet egress with SNAT (no traffic log without syslog); nothing from the hub or on-prem by default; transit is sloppy."
  }

  assert {
    condition     = length(regexall("set name \"lz-[0-9]+\"", terraform_data.fw_policy.input)) == 2 && strcontains(terraform_data.fw_policy.input, "set name \"lz-2\"")
    error_message = "With the VPN and no endpoint: 2 default policies, numbered from 1."
  }
}

run "hub_reaches_endpoint_backends_only" {
  command = plan

  variables {
    endpoint_backends = { api = { server_ips = ["10.96.8.10", "10.96.8.11"], port = 8080 } }
  }

  assert {
    condition = alltrue([
      can(regex("(?s)edit \"lz-ep-api\"\\s+set member \"net-10.96.8.10_32\" \"net-10.96.8.11_32\"", terraform_data.fw_policy.input)),
      can(regex("(?s)edit 2\\s+set name \"lz-2\"\\s+set comments \"\\[HUB\\] SRC=HUB_EGRESS_NET DST=api TCP/8080[^\"]*\"\\s+set srcintf \"port3\"\\s+set dstintf \"port3\"\\s+set srcaddr \"HUB_EGRESS_NET\"\\s+set dstaddr \"lz-ep-api\".*?set action accept.*?set service \"lz-tcp-8080\"", terraform_data.fw_policy.input)),
      can(regex("(?s)edit \"lz-tcp-8080\"\\s+set tcp-portrange 8080", terraform_data.fw_policy.input)),
    ])
    error_message = "A hub endpoint opens the hub egress network to its backend IPs, on its port only."
  }
}

run "egress_logged_with_syslog" {
  command = plan

  variables {
    syslog_relay_host = 5
  }

  assert {
    condition     = can(regex("(?s)\\[EGRESS\\].*?set logtraffic all", terraform_data.fw_policy.input))
    error_message = "With a remote collector, Internet sessions of the spokes are logged."
  }
}

run "customer_policy_goes_first" {
  command = plan

  variables {
    policy = {
      aliases = { MONITORING = ["10.0.4.50/32"] }
      rules = [
        { description = "Monitoring to genomic", action = "pass", source = "MONITORING", destination = "10.96.8.0/21", protocol = "tcp", port = 9100, port_end = 9101 },
        { description = "No SMTP out", action = "block", source = "SPOKE_NETS", destination = "any", protocol = "tcp", port = 25, state = "keep" },
      ]
    }
  }

  assert {
    condition = alltrue([
      can(regex("(?s)edit 1\\s+set name \"lz-1\"\\s+set comments \"Monitoring to genomic\"\\s+set srcintf \"port3\"\\s+set dstintf \"any\"\\s+set srcaddr \"MONITORING\"\\s+set dstaddr \"net-10.96.8.0_21\".*?set service \"lz-tcp-9100-9101\"", terraform_data.fw_policy.input)),
      can(regex("(?s)edit 2\\s+set name \"lz-2\"\\s+set comments \"No SMTP out\".*?set dstaddr \"all\".*?set action deny", terraform_data.fw_policy.input)),
      can(regex("(?s)edit 3\\s+set name \"lz-3\"\\s+set comments \"\\[EW\\]", terraform_data.fw_policy.input)),
      can(regex("(?s)edit \"lz-tcp-9100-9101\"\\s+set tcp-portrange 9100-9101", terraform_data.fw_policy.input)),
      can(regex("(?s)edit \"MONITORING\"\\s+set member \"net-10.0.4.50_32\"", terraform_data.fw_policy.input)),
    ])
    error_message = "Customer rules come first, with their aliases, CIDR addresses and port services."
  }
}

run "rejects_nat_outbound" {
  command = plan

  variables {
    policy = { nat_outbound = [{ description = "x", source = "SPOKE_NETS" }] }
  }

  expect_failures = [terraform_data.fw_policy]
}

run "rejects_image_and_snapshot" {
  command = plan

  variables {
    firewall = {
      nodes = {
        fw1 = { zone = "fr-par-1", image = "fortigate", snapshot_id = "fr-par-1/66666666-6666-6666-6666-666666666666" }
        fw2 = { zone = "fr-par-2", image = "fortigate" }
      }
    }
  }

  expect_failures = [var.firewall]
}

run "rejects_missing_license_file" {
  command = plan

  variables {
    firewall = {
      nodes = {
        fw1 = { zone = "fr-par-1", image = "fortigate", license_file = "/nonexistent.lic" }
        fw2 = { zone = "fr-par-2", image = "fortigate" }
      }
    }
  }

  expect_failures = [var.firewall]
}

run "existing_project_and_snapshot" {
  command = plan

  variables {
    project_id = "55555555-5555-5555-5555-555555555555"
    firewall = {
      nodes = {
        fw1 = { zone = "fr-par-1", snapshot_id = "fr-par-1/66666666-6666-6666-6666-666666666666" }
        fw2 = { zone = "fr-par-2", image = "fortigate" }
      }
    }
  }

  assert {
    condition     = length(scaleway_account_project.this) == 0 && output.project_id == "55555555-5555-5555-5555-555555555555"
    error_message = "An existing project must be used as is."
  }

  assert {
    condition     = length(scaleway_block_volume.fw) == 1 && scaleway_block_volume.fw["fw1"].zone == "fr-par-1" && scaleway_instance_server.fw["fw1"].boot_type == "local" && strcontains(nonsensitive(scaleway_instance_server.fw["fw1"].user_data["cloud-init"]), "set ssh-public-key1 \"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest admin\"")
    error_message = "A snapshot node boots from a fresh local volume in its zone, with its cloud-init user data (admin key)."
  }
}

run "management_is_private" {
  command = plan

  assert {
    condition     = length(scaleway_instance_private_nic.mgmt) == 2 && alltrue([for k in ["fw1", "fw2"] : strcontains(terraform_data.fw_config[k].input.platform, "edit \"port3\"\n        set alias \"hub\"")]) && strcontains(terraform_data.fw_config["fw1"].input.platform, "edit \"port2\"\n        set alias \"mgmt\"\n        set mode static\n        set ip 10.0.6.11 255.255.255.0")
    error_message = "A management NIC per node, attached first: port2 (port1 is the unused public NIC), static from the user data, hub on port3 (the module creates no public IP for the firewalls)."
  }

  assert {
    condition = alltrue([
      can(regex("(?s)config ha-mgmt-interfaces.*?set interface \"port2\"\\s+set gateway 10.0.6.2", terraform_data.fw_config["fw1"].input.platform)),
      can(regex("(?s)config ha-mgmt-interfaces.*?set interface \"port2\"\\s+set gateway 10.0.6.3", terraform_data.fw_config["fw2"].input.platform)),
      scaleway_ipam_ip.fw["fw1-mgmt"].address == "10.0.6.11",
      scaleway_vpc_gateway_network.mgmt["a"].enable_masquerade,
      one(scaleway_vpc_gateway_network.mgmt["b"].ipam_config).push_default_route,
    ])
    error_message = "Each node manages through the PGW of its zone; the PGWs give the management network a default route (licence activation at first boot)."
  }
  assert {
    condition = length(scaleway_instance_security_group.fw) == 2 && alltrue([for sg in scaleway_instance_security_group.fw : sg.stateful && sg.inbound_default_policy == "drop" && toset([for r in sg.inbound_rule : "${r.protocol} ${r.ip_range} ${r.port}"]) == toset([
      "TCP 10.0.6.2/32 22", "TCP 10.0.6.2/32 443", "TCP 10.0.6.3/32 22", "TCP 10.0.6.3/32 443",
    ])])
    error_message = "One firewall security group per zone (public and management NICs): SSH and HTTPS from the PGW bastions only."
  }
  assert {
    condition     = length(scaleway_vpc_public_gateway_pat_rule.admin) == 0 && !can(output.access.fw1.direct_ssh)
    error_message = "No direct admin access by default."
  }
}

run "direct_admin_access" {
  command = plan

  variables {
    admin_direct_access = true
  }

  assert {
    condition = toset([for r in scaleway_vpc_public_gateway_pat_rule.admin : "${r.zone} ${r.public_port}>${r.private_ip}:${r.private_port}/${r.protocol}"]) == toset([
      "fr-par-1 2222>10.0.6.11:22/tcp", "fr-par-1 8443>10.0.6.11:443/tcp", "fr-par-2 2222>10.0.6.12:22/tcp", "fr-par-2 8443>10.0.6.12:443/tcp",
    ])
    error_message = "Each PGW forwards 2222 and 8443 to SSH and HTTPS on the management IP of the node in its zone."
  }
  assert {
    condition = alltrue([for sg in scaleway_instance_security_group.fw : toset([for r in sg.inbound_rule : "${r.protocol} ${r.ip_range} ${r.port}"]) == toset([
      "TCP 10.0.6.2/32 22", "TCP 10.0.6.2/32 443", "TCP 10.0.6.3/32 22", "TCP 10.0.6.3/32 443", "TCP 203.0.113.10/32 22", "TCP 203.0.113.10/32 443",
    ])])
    error_message = "The firewall security group lets admin_cidrs in, since the PAT rules do not filter sources."
  }
}

run "remote_syslog" {
  command = plan

  variables {
    firewall = {
      syslog = [{ host = "10.0.4.20" }, { host = "logs.example.com", port = 6514, transport = "tcp" }]
      nodes = {
        fw1 = { zone = "fr-par-1", image = "fortigate" }
        fw2 = { zone = "fr-par-2", image = "fortigate" }
      }
    }
  }

  assert {
    condition = alltrue([
      can(regex("(?s)config log syslogd setting\\s+set status enable\\s+set server \"10.0.4.20\"\\s+set port 514\\s+set mode udp\\s+set format rfc5424", terraform_data.fw_config["fw1"].input.platform)),
      can(regex("(?s)config log syslogd2 setting\\s+set status enable\\s+set server \"logs.example.com\"\\s+set port 6514\\s+set mode reliable\\s+set format rfc5424", terraform_data.fw_config["fw2"].input.platform)),
    ])
    error_message = "Syslog collectors go to syslogd, syslogd2..., TCP as reliable, in RFC 5424."
  }
}

run "syslog_relay_added_once" {
  command = plan

  variables {
    syslog_relay_host = 5
    firewall = {
      syslog = [{ host = "logs.example.com" }, { host = "10.0.4.5" }]
      nodes = {
        fw1 = { zone = "fr-par-1", image = "fortigate" }
        fw2 = { zone = "fr-par-2", image = "fortigate" }
      }
    }
  }

  assert {
    condition     = length(regexall("set server \"10.0.4.5\"", terraform_data.fw_config["fw1"].input.platform)) == 1
    error_message = "The relay is sent the syslog once, even when firewall.syslog lists it too."
  }
}

run "syslog_relay_from_first_boot" {
  command = plan

  variables {
    syslog_relay_host = 5
  }

  assert {
    condition     = can(regex("(?s)config log syslogd setting\\s+set status enable\\s+set server \"10.0.4.5\"\\s+set port 514\\s+set mode udp", terraform_data.fw_config["fw2"].input.platform))
    error_message = "With a relay, the nodes send it their syslog from their first boot."
  }
}

run "internal_nets_cover_the_landing_zone" {
  command = plan

  variables {
    spoke_supernet = "100.64.0.0/10"
    interlink = {
      pop_id         = "fr-par/66666666-6666-6666-6666-666666666666"
      bandwidth_mbps = 1000
      partner_id     = "fr-par/77777777-7777-7777-7777-777777777777"
      onprem_cidrs   = ["10.10.0.0/16"]
    }
  }

  assert {
    condition = regex("edit \"internal_nets\"\\s+set member ([^\\n]*)", terraform_data.fw_policy.input)[0] == join(" ", [
      for c in ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "10.0.4.0/24", "172.16.0.0/24", "10.0.5.0/24", "10.0.6.0/24", "10.255.0.0/24", "10.10.0.0/16"] :
      "\"net-${replace(c, "/", "_")}\""
    ])
    error_message = "internal_nets must hold RFC1918, the spoke supernet, the hub networks and the on-prem ranges, once each."
  }
}

run "rejects_colliding_hosts" {
  command = plan

  variables {
    egress = { pgw_hosts = { a = 11 } }
  }

  expect_failures = [var.firewall]
}

run "rejects_quote_in_description" {
  command = plan

  variables {
    policy = {
      rules = [{ description = "x\" set action accept", action = "pass", source = "any", destination = "any" }]
    }
  }

  expect_failures = [var.policy]
}

run "rejects_unknown_alias" {
  command = plan

  variables {
    policy = {
      rules = [{ description = "Unknown alias", action = "pass", source = "NOPE", destination = "any" }]
    }
  }

  expect_failures = [var.policy]
}

run "vpn_ciphers" {
  command = plan

  variables {
    vpn = {
      customer_gateway_ip = "198.51.100.1"
      customer_asn        = 65010
      onprem_cidrs        = ["192.168.0.0/16"]
      ciphers             = { esp = { encryption = "aes128", dh_group = "modp3072" } }
    }
  }

  assert {
    condition = alltrue([
      scaleway_s2s_vpn_connection.this["a"].esp_ciphers[0].encryption == "aes128",
      scaleway_s2s_vpn_connection.this["a"].esp_ciphers[0].dh_group == "modp3072",
      scaleway_s2s_vpn_connection.this["a"].esp_ciphers[0].integrity == "sha256",
      scaleway_s2s_vpn_connection.this["a"].ikev2_ciphers[0].encryption == "aes256",
      scaleway_s2s_vpn_connection.this["a"].ikev2_ciphers[0].dh_group == "modp2048",
    ])
    error_message = "vpn.ciphers must override the proposals, the others keep the defaults."
  }
}

run "rejects_overlap_with_onprem" {
  command = plan

  variables {
    vpn = {
      customer_gateway_ip = "198.51.100.1"
      customer_asn        = 65010
      onprem_cidrs        = ["10.64.8.0/22"]
    }
  }

  expect_failures = [var.spoke_supernet]
}

run "rejects_overlap_between_dsi_networks" {
  command = plan

  variables {
    cidrs = { hub = "10.64.1.0/24" }
  }

  expect_failures = [var.spoke_supernet]
}
