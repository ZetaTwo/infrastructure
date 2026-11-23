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

resource "cloudflare_dns_record" "obfuscation_challenge_staging" {
  zone_id = var.cloudflare_zones["zetatwo_dev"] # staging, auth-gated — docs/app-setup.md
  name    = "obfuscation"
  type    = "A"
  content = hcloud_server.cluster_node[0].ipv4_address # node1 only, no multi-node routing yet
  ttl     = 1
  proxied = false # un-proxied: HTTP-01 must reach Traefik directly
}

resource "cloudflare_dns_record" "aoe2tm_staging" {
  zone_id = var.cloudflare_zones["zetatwo_dev"] # staging, auth-gated — docs/app-setup.md
  name    = "gatherpoint"
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

# setgatherpoint.com: Gather Point (aoe2tm) production. Prepared before
# launch, so only its mail records exist; the web record comes with the
# production overlay (docs/todo.md). The Google Workspace records (MX, apex
# SPF, google._domainkey, site verification) live outside Terraform
# (docs/messaging.md). Every record here waits for the zone:
# nothing is created until cloudflare_zones has a `setgatherpoint_com` entry
# (and the Cloudflare token covers the zone, docs/cluster-setup.md).
locals {
  setgatherpoint = contains(keys(var.cloudflare_zones), "setgatherpoint_com") ? {
    zone_id = var.cloudflare_zones["setgatherpoint_com"]
  } : null
  # The DKIM record Postmark shows for setgatherpoint.com (the aoe2tm-production
  # server sends as noreply@setgatherpoint.com).
  setgatherpoint_postmark_dkim = {
    selector = "20261123145727pm"
    value    = "k=rsa;p=MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCr5tIoO4OuTxlKMGaaBhpZHEKRIVMShdVNno2itIWLhGW2eJ1TSMhqwn2bUawWYDQS5kh5RD5Vz98517Y5ALMB1od4elTOqjy++/2w+vmsh4+pbWW8J06aGr1Z0ZPoILN87lUGEAeADE4+QCY7gW7lGAP4ZXFH0bcjupueOOip1QIDAQAB"
  }
  setgatherpoint_zone = local.setgatherpoint == null ? {} : { setgatherpoint = local.setgatherpoint }
}

# Bounces go to Postmark through the domain itself; SPF is checked here.
resource "cloudflare_dns_record" "setgatherpoint_mail_return_path" {
  for_each = local.setgatherpoint_zone
  zone_id  = each.value.zone_id
  name     = "pm-bounces"
  type     = "CNAME"
  content  = "pm.mtasv.net"
  ttl      = 1
  proxied  = false
}

resource "cloudflare_dns_record" "setgatherpoint_mail_dkim" {
  for_each = local.setgatherpoint_zone
  zone_id  = each.value.zone_id
  name     = "${local.setgatherpoint_postmark_dkim.selector}._domainkey"
  type     = "TXT"
  content  = "\"${local.setgatherpoint_postmark_dkim.value}\""
  ttl      = 1
}

# The same policy as zetatwo.dev: Postmark's DKIM signature
# (d=setgatherpoint.com) aligns strictly, so only mail that fails DKIM is
# rejected.
resource "cloudflare_dns_record" "setgatherpoint_dmarc" {
  for_each = local.setgatherpoint_zone
  zone_id  = each.value.zone_id
  name     = "_dmarc"
  type     = "TXT"
  content  = "\"v=DMARC1; p=reject; sp=reject; adkim=s; aspf=s\""
  ttl      = 1
}
