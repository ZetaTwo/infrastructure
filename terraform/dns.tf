# Explicit per-hostname DNS records — never a wildcard. Add one record here per
# new app (on apps_zone_id) or admin surface (on admin_zone_id).
#
# admin_zone_id / data.cloudflare_zone.admin has no record on it right now —
# reserved for future admin/management tooling (see README TODO).

resource "cloudflare_dns_record" "demo" {
  zone_id = var.apps_zone_id
  name    = "demo"
  type    = "A"
  content = hcloud_server.app.ipv4_address
  ttl     = 1
  proxied = false # must stay un-proxied so cert-manager's Let's Encrypt HTTP-01 challenge reaches Traefik directly
}
