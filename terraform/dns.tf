# Explicit per-hostname DNS records — never a wildcard. Add one record here per
# new app (on apps_zone_id) or admin surface (on admin_zone_id).

resource "cloudflare_dns_record" "demo" {
  zone_id = var.apps_zone_id
  name    = "demo"
  type    = "A"
  content = hcloud_server.app.ipv4_address
  ttl     = 1
  proxied = false # must stay un-proxied so Caddy's Let's Encrypt HTTP-01 challenge reaches the origin
}

resource "cloudflare_dns_record" "admin" {
  zone_id = var.admin_zone_id
  name    = "admin"
  type    = "A"
  content = hcloud_server.app.ipv4_address
  ttl     = 1
  proxied = false
}
