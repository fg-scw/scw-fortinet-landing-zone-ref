# terraform test - offline, no Scaleway API call.
mock_provider "scaleway" {}

variables {
  name               = "web"
  project_id         = "44444444-4444-4444-4444-444444444444"
  private_network_id = "fr-par/44444444-4444-4444-4444-444444444444"
  config = {
    zones   = ["fr-par-1", "fr-par-2"]
    backend = { server_ips = ["10.96.8.10"], port = 8080, health_check_uri = "/healthz" }
    edge    = { fqdns = ["app.example.com"] }
  }
}

run "behind_edge_services" {
  command = plan

  assert {
    condition     = length(scaleway_edge_services_backend_stage.this.lb_backend_config) == 2
    error_message = "Edge Services must balance across every zonal LB."
  }

  assert {
    condition     = length(scaleway_lb_acl.allow_edge) == 2 && length(scaleway_lb_acl.deny_others) == 2
    error_message = "Each LB must only accept Edge Services IPs."
  }
}

run "edge_needs_fqdn" {
  command = plan

  variables {
    config = {
      backend = { server_ips = ["10.96.8.10"], port = 8080 }
      edge    = { fqdns = [] }
    }
  }

  expect_failures = [var.config]
}
