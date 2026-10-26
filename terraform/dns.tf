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

# Outbound email via Postmark (docs/messaging.md). Each app environment sends
# from its own staging domain (noreply@canst.zetatwo.dev), never from
# zeta-two.com, so app mail can't affect the personal mail domain's
# reputation. Keys are labels in zetatwo.dev. A value is the DKIM record
# Postmark shows once the domain is added there (selector is the part before
# ._domainkey); null until then.
locals {
  mail_senders = {
    canst  = null # canst staging
    notify = null # Apprise's operator emails
    # canst = { selector = "20261026120000pm", value = "k=rsa;p=MIGf..." }
  }
}

# Postmark sends on its own IPs, so there's no MX or SPF record of our own:
# SPF alignment comes from this Return-Path, which sends bounces to Postmark.
resource "cloudflare_dns_record" "mail_return_path" {
  for_each = local.mail_senders
  zone_id  = var.cloudflare_zones["zetatwo_dev"]
  name     = "pm-bounces.${each.key}"
  type     = "CNAME"
  content  = "pm.mtasv.net"
  ttl      = 1
  proxied  = false
}

# Monitor only (p=none), no aggregate reports for now; tighten to quarantine
# once Postmark shows DKIM and Return-Path passing.
resource "cloudflare_dns_record" "mail_dmarc" {
  for_each = local.mail_senders
  zone_id  = var.cloudflare_zones["zetatwo_dev"]
  name     = "_dmarc.${each.key}"
  type     = "TXT"
  content  = "\"v=DMARC1; p=none\""
  ttl      = 1
}

resource "cloudflare_dns_record" "mail_dkim" {
  for_each = { for label, dkim in local.mail_senders : label => dkim if dkim != null }
  zone_id  = var.cloudflare_zones["zetatwo_dev"]
  name     = "${each.value.selector}._domainkey.${each.key}"
  type     = "TXT"
  content  = "\"${each.value.value}\""
  ttl      = 1
}
