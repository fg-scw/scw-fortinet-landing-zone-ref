output "project_id" {
  value = scaleway_account_project.this.id
}

output "cidrs" {
  value = { pub = local.pub_cidr, private = local.private_cidr }
}

output "private_network_ids" {
  value = {
    pub     = scaleway_vpc_private_network.pub.id
    private = scaleway_vpc_private_network.private.id
  }
}

# Contract consumed by the BU endpoint units (modules/endpoint).
output "endpoint_target" {
  value = {
    project_id         = scaleway_account_project.this.id
    private_network_id = scaleway_vpc_private_network.pub.id
    tags               = local.tags
  }
  depends_on = [scaleway_edge_services_plan.this]
}

output "iam_group_id" {
  value = scaleway_iam_group.this.id
}

output "hybrid_bypass" {
  value = local.bypass
}

# Baseline security groups to set on the BU Private Network interfaces:
# security_group_ids.<pub|private>.<zone>.
output "security_group_ids" {
  value = {
    for tier in ["pub", "private"] : tier => {
      for k, sg in scaleway_instance_security_group.baseline : sg.zone => sg.id if local.sg[k].tier == tier
    }
  }
}
