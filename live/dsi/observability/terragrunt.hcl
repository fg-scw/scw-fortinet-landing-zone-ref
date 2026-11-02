# OPTIONAL syslog relay (OPNsense -> Alloy -> Cockpit). Delete this folder, or
# never apply it, when the customer has its own SIEM: put its collector in
# firewall.syslog of live/dsi instead. Needs the scw CLI on the runner.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

locals {
  dsi_dir = dirname(get_terragrunt_dir())
  # Same keys as the DSI firewalls' root account.
  dsi_inputs = read_terragrunt_config("${local.dsi_dir}/terragrunt.hcl").inputs
}

terraform {
  source = "${include.root.locals.modules_dir}//observability"
}

dependency "dsi" {
  config_path = local.dsi_dir

  # destroy: retrying an interrupted destroy, the dependency may have no outputs.
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan", "destroy"]
  mock_outputs = {
    observability_target = {
      name               = "dsi-hub-obs"
      project_id         = "00000000-0000-0000-0000-000000000000"
      private_network_id = "fr-par/00000000-0000-0000-0000-000000000000"
      tags               = []
      zone               = "fr-par-1"
      egress_cidr        = "10.0.4.0/24"
      hub_cidr           = "172.16.0.0/24"
      pgw_hosts          = [2, 3]
      reserved_hosts     = [2, 3, 9, 10, 11, 12]
      bastion            = "bastion@203.0.113.1:61000"
    }
  }
}

inputs = merge(
  # Network values come from the DSI: no copy to keep in line by hand.
  { for k, v in dependency.dsi.outputs.observability_target : k => v if k != "tags" },
  {
    tags                  = concat(dependency.dsi.outputs.observability_target.tags, ["observability"])
    admin_ssh_public_keys = local.dsi_inputs.admin_ssh_public_keys
    # host = 5   # relay host number in the egress network, must be free
  },
)
