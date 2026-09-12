data "cloudflare_zone" "this" {
  for_each = var.cloudflare_zones
  zone_id  = each.value
}
