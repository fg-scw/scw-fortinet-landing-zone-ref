# Common configuration of a public endpoint unit (Load Balancers, optional
# Edge Services). Layout: <owner>/endpoints/<name>/terragrunt.hcl where
# <owner> is live/dsi (Egress network) or live/bus/<bu> (BU Pub network).
# The unit only adds `inputs = { config = { ... } }` (see modules/endpoint).

locals {
  root_dir  = dirname(find_in_parent_folders("root.hcl"))
  owner_dir = dirname(dirname(get_terragrunt_dir()))
}

terraform {
  source = "${local.root_dir}/../modules//endpoint"
}

dependency "owner" {
  config_path = local.owner_dir

  # destroy: retrying an interrupted destroy, the dependency may have no outputs.
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan", "destroy"]
  mock_outputs = {
    endpoint_target = {
      project_id         = "00000000-0000-0000-0000-000000000000"
      private_network_id = "fr-par/00000000-0000-0000-0000-000000000000"
      tags               = []
    }
  }
}

inputs = {
  name               = "${basename(local.owner_dir)}-${basename(get_terragrunt_dir())}"
  project_id         = dependency.owner.outputs.endpoint_target.project_id
  private_network_id = dependency.owner.outputs.endpoint_target.private_network_id
  tags               = concat(dependency.owner.outputs.endpoint_target.tags, ["endpoint:${basename(get_terragrunt_dir())}"])
}
