# Public exposure: Edge Services (TLS, WAF) -> one Load Balancer per zone ->
# backends on the attached Private Network or any VPC routed from it.
# The Edge Services plan is a per-project subscription owned by the caller.

resource "scaleway_lb_ip" "this" {
  for_each = toset(var.config.zones)

  project_id = var.project_id
  zone       = each.key
  tags       = var.tags
}

resource "scaleway_lb" "this" {
  for_each = toset(var.config.zones)

  name       = "${var.name}-${each.key}"
  project_id = var.project_id
  zone       = each.key
  type       = var.config.lb_type
  ip_ids     = [scaleway_lb_ip.this[each.key].id]
  tags       = var.tags

  private_network {
    private_network_id = var.private_network_id
  }
}

resource "scaleway_lb_backend" "this" {
  for_each = scaleway_lb.this

  name             = var.name
  lb_id            = each.value.id
  forward_protocol = var.config.backend.protocol
  forward_port     = var.config.backend.port
  server_ips       = var.config.backend.server_ips

  dynamic "health_check_http" {
    for_each = var.config.backend.health_check_uri == null ? [] : [var.config.backend.health_check_uri]
    content {
      uri = health_check_http.value
    }
  }

  dynamic "health_check_tcp" {
    for_each = var.config.backend.health_check_uri == null ? [1] : []
    content {}
  }
}

resource "scaleway_lb_frontend" "this" {
  for_each = scaleway_lb.this

  name          = var.name
  lb_id         = each.value.id
  backend_id    = scaleway_lb_backend.this[each.key].id
  inbound_port  = var.config.frontend_port
  external_acls = true
}

# Behind Edge Services, the LB only answers Edge Services IPs.
resource "scaleway_lb_acl" "allow_edge" {
  for_each = scaleway_lb_frontend.this

  name        = "allow-edge-services"
  frontend_id = each.value.id
  index       = 0

  action { type = "allow" }
  match { ips_edge_services = true }
}

resource "scaleway_lb_acl" "deny_others" {
  for_each = scaleway_lb_frontend.this

  name        = "deny-others"
  frontend_id = each.value.id
  index       = 1

  action { type = "deny" }
  match { ip_subnet = ["0.0.0.0/0"] }
}

# --- Edge Services pipeline: DNS -> TLS -> WAF -> LBs ------------------------

resource "scaleway_edge_services_pipeline" "this" {
  name       = var.name
  project_id = var.project_id
}

resource "scaleway_edge_services_backend_stage" "this" {
  pipeline_id = scaleway_edge_services_pipeline.this.id
  project_id  = var.project_id

  dynamic "lb_backend_config" {
    for_each = scaleway_lb.this
    content {
      lb_config {
        id          = lb_backend_config.value.id
        frontend_id = scaleway_lb_frontend.this[lb_backend_config.key].id
        zone        = lb_backend_config.key
        is_ssl      = false
        domain_name = var.config.edge.fqdns[0]
      }
    }
  }
}

resource "scaleway_edge_services_waf_stage" "this" {
  pipeline_id      = scaleway_edge_services_pipeline.this.id
  project_id       = var.project_id
  backend_stage_id = scaleway_edge_services_backend_stage.this.id
  mode             = var.config.edge.waf_mode
  paranoia_level   = var.config.edge.paranoia_level
}

resource "scaleway_edge_services_tls_stage" "this" {
  pipeline_id         = scaleway_edge_services_pipeline.this.id
  project_id          = var.project_id
  waf_stage_id        = scaleway_edge_services_waf_stage.this.id
  managed_certificate = true
}

resource "scaleway_edge_services_dns_stage" "this" {
  pipeline_id  = scaleway_edge_services_pipeline.this.id
  project_id   = var.project_id
  tls_stage_id = scaleway_edge_services_tls_stage.this.id
  fqdns        = var.config.edge.fqdns
}

resource "scaleway_edge_services_head_stage" "this" {
  pipeline_id   = scaleway_edge_services_pipeline.this.id
  head_stage_id = scaleway_edge_services_dns_stage.this.id
}
