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

resource "cloudflare_dns_record" "canst_staging" {
  zone_id = var.cloudflare_zones["zetatwo_dev"] # staging, auth-gated — docs/app-setup.md
  name    = "canst"
  type    = "A"
  content = hcloud_server.cluster_node[0].ipv4_address # node1 only, no multi-node routing yet
  ttl     = 1
  proxied = false # un-proxied: HTTP-01 must reach Traefik directly
}

resource "cloudflare_dns_record" "aoe2tm_staging" {
  zone_id = var.cloudflare_zones["zetatwo_dev"] # staging, auth-gated — docs/app-setup.md
  name    = "aoe2tm"
  type    = "A"
  content = hcloud_server.cluster_node[0].ipv4_address # node1 only, no multi-node routing yet
  ttl     = 1
  proxied = false # un-proxied: HTTP-01 must reach Traefik directly
}

# Outbound email via Postmark (docs/messaging.md): every app sends from the
# zetatwo.dev apex (canst@zetatwo.dev, notify@zetatwo.dev), never from
# zeta-two.com.
#
# The apex's other mail records predate this and live outside Terraform:
# SPF "v=spf1 -all", DMARC "p=reject; sp=reject; adkim=s; aspf=s", and a
# null DKIM wildcard. They stay as they are. Postmark's DKIM signature
# (d=zetatwo.dev) aligns even strictly, which is all DMARC needs, so only
# mail that fails DKIM is rejected. SPF is checked on the Return-Path
# below, not the apex, so "-all" doesn't apply to it. The selector record
# below takes precedence over the wildcard.
locals {
  # The DKIM record Postmark shows for zetatwo.dev; the selector is the part
  # before ._domainkey.
  postmark_dkim = {
    selector = "20261026194324pm"
    value    = "k=rsa;p=MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCLZ3gqkN5nthU1izVohQ2tflkqs1scr2tSV67KOd9MVLukjzLc9O01zEfyySHMfIvyIYUR0TPOuGsZsXNfIxTFurJ0FzCzUlP6uOaVjjJkJXd9WhIw5ugCg5h11EgLulNxEKaOMVskquuD4YBqmwr+ZzpbUMuER783Qfz9oANHCwIDAQAB"
  }
}

# Bounces go to Postmark through our own domain.
resource "cloudflare_dns_record" "mail_return_path" {
  zone_id = var.cloudflare_zones["zetatwo_dev"]
  name    = "pm-bounces"
  type    = "CNAME"
  content = "pm.mtasv.net"
  ttl     = 1
  proxied = false
}

resource "cloudflare_dns_record" "mail_dkim" {
  for_each = local.postmark_dkim == null ? {} : { postmark = local.postmark_dkim }
  zone_id  = var.cloudflare_zones["zetatwo_dev"]
  name     = "${each.value.selector}._domainkey"
  type     = "TXT"
  content  = "\"${each.value.value}\""
  ttl      = 1
}
