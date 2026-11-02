include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "endpoint" {
  path = find_in_parent_folders("endpoint.hcl")
}

# Example: frontends of the genomic BU, one LB per zone behind Edge Services.
inputs = {
  config = {
    zones = ["fr-par-1", "fr-par-2"]
    backend = {
      server_ips       = ["10.96.8.10", "10.96.8.11"] # genomic Private (index 1)
      port             = 8080
      health_check_uri = "/healthz"
    }
    edge = {
      fqdns = ["genomic.example.com"]
    }
  }
}
