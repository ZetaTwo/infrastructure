resource "local_file" "ansible_inventory" {
  filename = "${path.module}/../ansible/inventory/hosts.yaml"
  content = templatefile("${path.module}/templates/hosts.yaml.tftpl", {
    server_host  = hcloud_server.app.ipv4_address
    apps_domain  = data.cloudflare_zone.apps.name
    admin_domain = data.cloudflare_zone.admin.name
  })
}
