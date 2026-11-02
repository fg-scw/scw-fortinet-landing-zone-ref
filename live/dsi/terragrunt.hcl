include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${include.root.locals.modules_dir}//dsi"
}

locals {
  # Optional customer policy next to this file (see policy.yaml.example).
  # Absent, empty or fully commented: no custom policy. A syntax error must
  # fail the plan, never silently apply an empty policy to running firewalls
  # (yamldecode itself rejects an empty document, hence the content check).
  policy_file = "${get_terragrunt_dir()}/policy.yaml"
  policy_raw  = fileexists(local.policy_file) ? file(local.policy_file) : ""
  policy      = length(regexall("(?m)^\\s*[^#\\s]", local.policy_raw)) > 0 ? yamldecode(local.policy_raw) : {}
}

inputs = {
  name   = "dsi-hub"
  policy = local.policy

  # Public IPs allowed on the Public Gateway SSH bastion (the Terraform runner
  # included: it checks new firewalls and pushes the policy through it).
  admin_cidrs           = ["203.0.113.10/32"]
  admin_ssh_public_keys = ["ssh-ed25519 AAAA_REPLACE_ME admin@dsi"]

  # Factory FortiOS KVM snapshot of each zone (README, Déploiement), or a zone-local
  # image ID, and the licence file of each node (.lic, never committed). The
  # node zones also set the zones of the Public Gateways and VPN gateways.
  firewall = {
    instance_type = "POP2-2C-8G"
    nodes = {
      fw1 = { zone = "fr-par-1", snapshot_id = "fr-par-1/<uuid of the factory snapshot>", license_file = "${get_terragrunt_dir()}/licenses/fw1.lic" }
      fw2 = { zone = "fr-par-2", snapshot_id = "fr-par-2/<uuid of the factory snapshot>", license_file = "${get_terragrunt_dir()}/licenses/fw2.lic" }
    }
  }

  # Edge Services subscription, needed by DSI endpoints (dsi/endpoints/<name>) using Edge.
  # edge_services_plan = "starter"

  # Inspected on-prem access (Egress VPC). Uncomment to enable.
  # vpn = {
  #   customer_gateway_ip = "198.51.100.1"
  #   customer_asn        = 65010
  #   onprem_cidrs        = ["192.168.0.0/16"]
  # }

  # Uninspected on-prem access for BU Private VPCs (Hybrid VPC). Uncomment to enable.
  # interlink = {
  #   pop_id         = "fr-par/<pop-uuid>"
  #   bandwidth_mbps = 1000
  #   partner_id     = "fr-par/<partner-uuid>"
  #   onprem_cidrs   = ["10.10.0.0/16"]
  # }
}
