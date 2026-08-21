resource "hcloud_ssh_key" "zetatwo" {
  name       = "zetatwo"
  public_key = file("${path.module}/files/zetatwo.pub")
}

resource "hcloud_server" "app" {
  name         = "app-server"
  server_type  = var.server_type
  location     = var.server_location
  image        = var.server_image
  ssh_keys     = [hcloud_ssh_key.zetatwo.id]
  firewall_ids = [hcloud_firewall.app.id]

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }
}
