resource "local_file" "ansible_inventory" {
  filename = "${path.module}/../ansible/inventory/hosts.yaml"
  content = templatefile("${path.module}/templates/hosts.yaml.tftpl", {
    server_host = hcloud_server.cluster_node.ipv4_address
    domains     = { for label, zone in data.cloudflare_zone.this : label => zone.name }
  })
}
