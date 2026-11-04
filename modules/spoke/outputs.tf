output "cidrs" {
  value = { pub = local.pub_cidr, private = local.private_cidr }
}

output "private_network_ids" {
  value = {
    pub     = scaleway_vpc_private_network.pub.id
    private = scaleway_vpc_private_network.private.id
  }
}

# Consumed by modules/endpoint for the endpoints this spoke owns.
output "endpoint_target" {
  value = {
    project_id         = var.hub.project_id
    private_network_id = scaleway_vpc_private_network.pub.id
    tags               = local.tags
  }
}

output "hybrid_bypass" {
  value = local.bypass
}

# Baseline security group IDs by tier and zone: security_group_ids.<pub|private>.<zone>.
output "security_group_ids" {
  value = {
    for tier in ["pub", "private"] : tier => {
      for k, sg in scaleway_instance_security_group.baseline : sg.zone => sg.id if local.sg[k].tier == tier
    }
  }
}
