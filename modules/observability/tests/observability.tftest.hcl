# terraform test - offline, no Scaleway API call.
mock_provider "scaleway" {
  mock_resource "scaleway_instance_server" {
    defaults = { id = "fr-par-1/44444444-4444-4444-4444-444444444444" }
  }
  mock_resource "scaleway_ipam_ip" {
    defaults = { id = "fr-par/44444444-4444-4444-4444-444444444444" }
  }
}

override_resource {
  target          = scaleway_cockpit_source.logs
  override_during = plan
  values          = { push_url = "https://abc.logs.cockpit.fr-par.scw.cloud/loki/api/v1/push" }
}

override_resource {
  target          = scaleway_cockpit_token.relay
  override_during = plan
  values          = { secret_key = "11111111-1111-1111-1111-111111111111" }
}

variables {
  project_id            = "44444444-4444-4444-4444-444444444444"
  private_network_id    = "fr-par/44444444-4444-4444-4444-444444444444"
  admin_ssh_public_keys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest admin"]
}

run "secret_only_in_server_user_data" {
  command = plan

  assert {
    condition     = !strcontains(scaleway_instance_user_data.cloud_init.value, "11111111-1111-1111-1111-111111111111")
    error_message = "the Cockpit token must not appear in the cloud-init key"
  }
  assert {
    condition     = strcontains(nonsensitive(scaleway_instance_server.relay.user_data["lz_secrets"]), "COCKPIT_TOKEN='11111111-1111-1111-1111-111111111111'")
    error_message = "lz_secrets must carry the token in the server user_data"
  }
  assert {
    condition     = strcontains(scaleway_instance_user_data.cloud_init.value, "per-boot/lz-obs") && strcontains(scaleway_instance_user_data.cloud_init.value, "disable_root: false")
    error_message = "per-boot launcher and root SSH settings expected"
  }
  assert {
    condition     = scaleway_cockpit_source.logs.type == "logs" && scaleway_cockpit_source.logs.retention_days == 31 && scaleway_cockpit_token.relay.scopes[0].write_logs
    error_message = "logs source (31 days) and write-only token expected"
  }
}

run "alloy_config" {
  command = plan

  assert {
    condition     = strcontains(scaleway_instance_user_data.cloud_init.value, "address       = \"10.0.4.5:514\"") && strcontains(scaleway_instance_user_data.cloud_init.value, "protocol      = \"udp\"") && strcontains(scaleway_instance_user_data.cloud_init.value, "protocol      = \"tcp\"")
    error_message = "Alloy must listen on 10.0.4.5:514 in UDP and TCP"
  }
  assert {
    condition     = strcontains(scaleway_instance_user_data.cloud_init.value, "program=\\\"filterlog\\\"") && strcontains(scaleway_instance_user_data.cloud_init.value, "loki.process.volume.receiver")
    error_message = "filterlog must be dropped by default"
  }
  assert {
    condition     = strcontains(scaleway_instance_user_data.cloud_init.value, "url     = \"https://abc.logs.cockpit.fr-par.scw.cloud/loki/api/v1/push\"") && strcontains(scaleway_instance_user_data.cloud_init.value, "sys.env(\"COCKPIT_TOKEN\")")
    error_message = "push endpoint and token from the environment expected"
  }
}

run "keep_filterlog" {
  command = plan
  variables {
    keep_filterlog = true
  }

  assert {
    condition     = !strcontains(scaleway_instance_user_data.cloud_init.value, "filterlog")
    error_message = "no filter expected with keep_filterlog"
  }
}

run "nftables" {
  command = plan

  assert {
    condition     = strcontains(scaleway_instance_user_data.cloud_init.value, "ip saddr { 10.0.4.0/24, 172.16.0.0/24 } udp dport 514 accept") && strcontains(scaleway_instance_user_data.cloud_init.value, "ip saddr { 10.0.4.0/24, 172.16.0.0/24 } tcp dport 514 accept")
    error_message = "514 only from the egress and hub CIDRs"
  }
  assert {
    condition     = strcontains(scaleway_instance_user_data.cloud_init.value, "ip saddr { 10.0.4.2, 10.0.4.3 } tcp dport 22 accept") && strcontains(scaleway_instance_user_data.cloud_init.value, "policy drop")
    error_message = "SSH only from the Public Gateways, default drop"
  }
}

run "outputs" {
  command = plan

  assert {
    condition     = output.syslog_target == { host = "10.0.4.5", port = 514, transport = "udp" }
    error_message = "syslog_target mismatch"
  }
}
