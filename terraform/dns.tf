# Explicit per-hostname DNS records — never a wildcard. Labels in
# var.cloudflare_zones aren't tied to a purpose; any label works for any
# record.

# Ansible/SSH target per node (terraform/inventory.tf) instead of a raw IP.
resource "cloudflare_dns_record" "cluster_node" {
  count   = var.node_count
  zone_id = var.cloudflare_zones["zetatwo_dev"]
  name    = "node${count.index + 1}"
  type    = "A"
  content = hcloud_server.cluster_node[count.index].ipv4_address
  ttl     = 1
  proxied = false
}

resource "cloudflare_dns_record" "aoe2_groups" {
  zone_id = var.cloudflare_zones["zetatwo_com"]
  name    = "aoe2-groups"
  type    = "A"
  content = hcloud_server.cluster_node[0].ipv4_address # node1 only, no multi-node routing yet
  ttl     = 1
  proxied = false # un-proxied: HTTP-01 must reach Traefik directly
}

resource "cloudflare_dns_record" "grafana" {
  zone_id = var.cloudflare_zones["zetatwo_dev"] # admin surface — docs/cluster-setup.md
  name    = "grafana"
  type    = "A"
  content = hcloud_server.cluster_node[0].ipv4_address # node1 only, no multi-node routing yet
  ttl     = 1
  proxied = false # un-proxied: HTTP-01 must reach Traefik directly
}

resource "cloudflare_dns_record" "aoe2_groups_staging" {
  zone_id = var.cloudflare_zones["zetatwo_dev"] # staging, auth-gated — docs/app-setup.md
  name    = "aoe2-groups"
  type    = "A"
  content = hcloud_server.cluster_node[0].ipv4_address # node1 only, no multi-node routing yet
  ttl     = 1
  proxied = false # un-proxied: HTTP-01 must reach Traefik directly
}

resource "cloudflare_dns_record" "auth" {
  zone_id = var.cloudflare_zones["zetatwo_dev"] # admin surface — docs/cluster-setup.md
  name    = "auth"
  type    = "A"
  content = hcloud_server.cluster_node[0].ipv4_address # node1 only, no multi-node routing yet
  ttl     = 1
  proxied = false # un-proxied: HTTP-01 must reach Traefik directly
}
