# Offline plan checks of the root wiring, no Scaleway API call.
mock_provider "scaleway" {
  # The provider validates ID formats, so mock IDs must look realistic.
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
  admin_ssh_public_keys = ["ssh-ed25519 AAAA test"]
  firewall = {
    nodes = {
      fw1 = { zone = "fr-par-1", snapshot_id = "fr-par-1/44444444-4444-4444-4444-444444444444" }
      fw2 = { zone = "fr-par-2", snapshot_id = "fr-par-2/44444444-4444-4444-4444-444444444444" }
    }
  }
  spokes = {
    genomic = { index = 1 }
    hr      = { index = 2 }
  }
  endpoints = {
    web = { owner = "genomic", config = { backend = { server_ips = ["10.96.8.10"], port = 8080 }, edge = { fqdns = ["web.example.com"] } } }
    api = { owner = "hub", config = { backend = { server_ips = ["10.0.4.20"], port = 443 }, edge = { fqdns = ["api.example.com"] } } }
  }
  edge_services_plan = "starter"
  observability      = true
}

run "wiring" {
  command = plan

  assert {
    condition     = output.spokes["genomic"].cidrs == { pub = "10.64.4.0/22", private = "10.96.8.0/21" } && output.spokes["hr"].cidrs.private == "10.96.16.0/21"
    error_message = "Each spoke gets the slot of its index."
  }

  assert {
    condition     = module.endpoint["web"].lb_public_ips != null && length(module.observability) == 1
    error_message = "One endpoint per entry, observability on demand."
  }
}

run "endpoints_need_edge_plan" {
  command = plan

  variables {
    edge_services_plan = null
  }

  expect_failures = [var.endpoints]
}

# Covers a customer policy file. A conditional on the decoded YAML fails with
# inconsistent types, hence the string check in main.tf.
run "policy_file" {
  command = plan

  variables {
    policy_file = "tests/policy.yaml"
  }
}

run "unknown_owner" {
  command = plan

  variables {
    endpoints = { web = { owner = "nope", config = { backend = { server_ips = ["10.96.8.10"], port = 8080 } } } }
  }

  expect_failures = [var.endpoints]
}
