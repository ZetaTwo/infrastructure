output "server_ipv4" {
  value = hcloud_server.app.ipv4_address
}

output "server_name" {
  value = hcloud_server.app.name
}
