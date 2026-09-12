resource "local_file" "ansible_inventory" {
  filename = "${path.module}/../ansible/inventory/hosts.yaml"
  content = templatefile("${path.module}/templates/hosts.yaml.tftpl", {
    server_hosts = [
      for server in hcloud_server.cluster_node :
      "${server.name}.${data.cloudflare_zone.this["zetatwo_dev"].name}"
    ]
    domains = { for label, zone in data.cloudflare_zone.this : label => zone.name }
  })
}
