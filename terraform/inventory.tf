resource "local_file" "ansible_inventory" {
  filename = "${path.module}/../ansible/inventory/hosts.yaml"
  content = templatefile("${path.module}/templates/hosts.yaml.tftpl", {
    server_fqdn  = cloudflare_dns_record.admin.name
    apps_domain  = data.cloudflare_zone.apps.name
    admin_domain = data.cloudflare_zone.admin.name
  })
}
