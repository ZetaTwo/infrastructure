data "cloudflare_zone" "apps" {
  zone_id = var.apps_zone_id
}

data "cloudflare_zone" "admin" {
  zone_id = var.admin_zone_id
}
