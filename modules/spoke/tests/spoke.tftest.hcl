# terraform test - offline, no Scaleway API call.
mock_provider "scaleway" {}

variables {
  name = "genomic"
  registry = {
    genomic = { index = 0 }
    rh = {
      index         = 5
      hybrid_bypass = true
      nacl_inbound  = [{ to = "private", source = "192.168.0.0/16", port = 5432 }]
    }
  }
  hub = {
    project_id      = "33333333-3333-3333-3333-333333333333"
    hub_vpc_id      = "fr-par/11111111-1111-1111-1111-111111111111"
    hybrid_vpc_id   = "fr-par/22222222-2222-2222-2222-222222222222"
    spoke_pools     = { pub = "10.64.0.0/12", private = "10.96.0.0/11" }
    interlink_cidrs = ["192.168.0.0/16"]
    zones           = ["fr-par-1", "fr-par-2"]
  }
}

run "slot_zero_without_bypass" {
  command = plan

  assert {
    condition     = output.cidrs.pub == "10.64.0.0/22" && output.cidrs.private == "10.96.0.0/21"
    error_message = "Index 0 must map to the first slot of each pool."
  }

  assert {
    condition     = length(scaleway_vpc_connector.private_to_hybrid) == 0 && length(scaleway_vpc_route.private_to_onprem) == 0
    error_message = "No hybrid resources without hybrid_bypass."
  }
}

run "slot_five_with_bypass" {
  command = plan

  variables {
    name = "rh"
  }

  assert {
    condition     = output.cidrs.pub == "10.64.20.0/22" && output.cidrs.private == "10.96.40.0/21"
    error_message = "Index 5 must map to the sixth /22 and /21."
  }

  assert {
    condition     = length(scaleway_vpc_connector.hybrid_to_private) == 1 && length(scaleway_vpc_route.private_to_onprem) == 1
    error_message = "hybrid_bypass must peer Private with Hybrid and route on-prem through it."
  }

  assert {
    condition     = length(scaleway_vpc_acl.this["pub"].rules) == 6 && length(scaleway_vpc_acl.this["private"].rules) == 7
    error_message = "NACLs: 6 baseline rules on Pub; 5 baseline + 1 bypass + 1 inbound on Private."
  }

  assert {
    condition = anytrue([for r in scaleway_vpc_acl.this["private"].rules :
    r.source == "192.168.0.0/16" && r.destination == "10.96.40.0/21" && r.dst_port_low == 5432 && r.dst_port_high == 5432])
    error_message = "nacl_inbound must open the declared port on the spoke Private CIDR."
  }

  assert {
    condition     = scaleway_vpc_acl.this["pub"].default_policy == "drop" && output.endpoint_target.project_id == var.hub.project_id
    error_message = "Default-deny NACL; endpoints go to the hub project."
  }
}

run "bypass_needs_interlink" {
  command = plan

  variables {
    name = "rh"
    hub = {
      project_id      = "33333333-3333-3333-3333-333333333333"
      hub_vpc_id      = "fr-par/11111111-1111-1111-1111-111111111111"
      hybrid_vpc_id   = "fr-par/22222222-2222-2222-2222-222222222222"
      spoke_pools     = { pub = "10.64.0.0/12", private = "10.96.0.0/11" }
      interlink_cidrs = []
      zones           = ["fr-par-1"]
    }
  }

  assert {
    condition     = output.hybrid_bypass == false
    error_message = "Without Interlink there is nothing to bypass to."
  }
}

run "duplicate_index_rejected" {
  command = plan

  variables {
    registry = {
      genomic = { index = 3 }
      rh      = { index = 3 }
    }
  }

  expect_failures = [var.registry]
}

run "index_out_of_range_rejected" {
  command = plan

  variables {
    registry = {
      genomic = { index = 1024 }
    }
  }

  expect_failures = [var.registry]
}

run "unregistered_bu_rejected" {
  command = plan

  variables {
    name = "marketing"
  }

  expect_failures = [var.registry]
}

run "invalid_nacl_rule_rejected" {
  command = plan

  variables {
    registry = {
      genomic = { index = 1, nacl_inbound = [{ to = "dmz", source = "10.0.0.0/8" }] }
    }
  }

  expect_failures = [var.registry]
}

run "baseline_security_groups" {
  command = plan

  variables {
    name = "rh"
  }

  assert {
    condition     = alltrue([for sg in scaleway_instance_security_group.baseline : sg.stateful && sg.inbound_default_policy == "drop" && sg.outbound_default_policy == "accept"]) && length(scaleway_instance_security_group.baseline) == 4
    error_message = "One stateful, inbound-drop baseline per tier and zone."
  }

  assert {
    condition = toset([for r in scaleway_instance_security_group.baseline["private-fr-par-1"].inbound_rule : "${r.protocol} ${r.ip_range} ${coalesce(r.port, 0)} ${coalesce(r.port_range, "-")}"]) == toset([
      "ICMP 0.0.0.0/0 0 -",
      "ANY 10.96.40.0/21 0 -",     # intra Private Network
      "ANY 10.64.20.0/22 0 -",     # from Pub
      "ANY 192.168.0.0/16 0 -",    # Interlink bypass
      "TCP 192.168.0.0/16 5432 -", # var.spokes nacl_inbound
    ])
    error_message = "Private baseline: intra-PN, Pub, Interlink bypass and nacl_inbound, nothing else (no ephemeral range)."
  }

  assert {
    condition     = toset([for r in scaleway_instance_security_group.baseline["pub-fr-par-2"].inbound_rule : "${r.protocol} ${r.ip_range}"]) == toset(["ICMP 0.0.0.0/0", "ANY 10.64.20.0/22"])
    error_message = "Pub baseline: ICMP and intra-PN only when var.spokes opens nothing to Pub."
  }
}

run "intra_pn_closed" {
  command = plan

  variables {
    registry = {
      genomic = {
        index        = 0
        intra_pn     = false
        nacl_inbound = [{ to = "pub", source = "10.0.4.0/24", port = 8000, port_end = 8099 }]
      }
    }
  }

  assert {
    condition     = toset([for r in scaleway_instance_security_group.baseline["pub-fr-par-1"].inbound_rule : "${r.protocol} ${r.ip_range} ${coalesce(r.port_range, "-")}"]) == toset(["ICMP 0.0.0.0/0 -", "TCP 10.0.4.0/24 8000-8099"])
    error_message = "intra_pn: false drops the Private Network rule; a port range becomes port_range."
  }
}
