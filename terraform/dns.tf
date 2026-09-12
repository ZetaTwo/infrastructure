# Explicit per-hostname DNS records — never a wildcard. Add one record here
# per hostname, picking any label from var.cloudflare_zones as its zone —
# labels aren't tied to a specific purpose (e.g. a "dev" hostname can live on
# the "zetatwo_dev" zone, or any other label added to cloudflare_zones), so
# adding a zone or repurposing one doesn't require any changes outside tfvars.

# One DNS name per cluster node (node1, node2, ...) — used as the
# Ansible/SSH target (see terraform/inventory.tf) instead of a raw IP, so it
# keeps working if a node's address ever changes. k3s clustering/join
# between nodes isn't wired up yet — see var.node_count in variables.tf.
resource "cloudflare_dns_record" "cluster_node" {
  count   = var.node_count
  zone_id = var.cloudflare_zones["zetatwo_dev"]
  name    = "node${count.index + 1}"
  type    = "A"
  content = hcloud_server.cluster_node[count.index].ipv4_address
  ttl     = 1
  proxied = false
}

resource "cloudflare_dns_record" "demo" {
  zone_id = var.cloudflare_zones["zetatwo_com"]
  name    = "demo"
  type    = "A"
  content = hcloud_server.cluster_node[0].ipv4_address # node1, until multi-node ingress/routing exists
  ttl     = 1
  proxied = false # must stay un-proxied so cert-manager's Let's Encrypt HTTP-01 challenge reaches Traefik directly
}
