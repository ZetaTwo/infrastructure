# Explicit per-hostname DNS records — never a wildcard. Add one record here
# per hostname, picking any label from var.cloudflare_zones as its zone —
# labels aren't tied to a specific purpose (e.g. a "dev" hostname can live on
# the "zetatwo_dev" zone, or any other label added to cloudflare_zones), so
# adding a zone or repurposing one doesn't require any changes outside tfvars.
#
# cloudflare_zones["zetatwo_dev"] has no record on it right now — reserved
# for future admin/management tooling (see README TODO).

resource "cloudflare_dns_record" "demo" {
  zone_id = var.cloudflare_zones["zetatwo_com"]
  name    = "demo"
  type    = "A"
  content = hcloud_server.cluster_node.ipv4_address
  ttl     = 1
  proxied = false # must stay un-proxied so cert-manager's Let's Encrypt HTTP-01 challenge reaches Traefik directly
}
