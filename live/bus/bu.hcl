# Common configuration of a BU unit. A BU folder only includes root.hcl and
# this file: its name is the folder name, its slot comes from bus.yaml.

locals {
  root_dir = dirname(find_in_parent_folders("root.hcl"))
}

terraform {
  source = "${local.root_dir}/../modules//bu"
}

dependency "dsi" {
  config_path = "${local.root_dir}/dsi"

  # Lets `plan` run before the DSI unit has been applied once, and `destroy`
  # be retried after an interrupted one left the dependency without outputs.
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan", "destroy"]
  mock_outputs = {
    bu_contract = {
      hub_vpc_id      = "fr-par/00000000-0000-0000-0000-000000000000"
      hybrid_vpc_id   = "fr-par/00000000-0000-0000-0000-000000000000"
      bu_pools        = { pub = "10.64.0.0/12", private = "10.96.0.0/11" }
      interlink_cidrs = []
      zones           = ["fr-par-1", "fr-par-2"]
    }
  }
}

inputs = {
  name     = basename(get_terragrunt_dir())
  registry = yamldecode(file("${local.root_dir}/bus.yaml"))
  dsi      = dependency.dsi.outputs.bu_contract
}
