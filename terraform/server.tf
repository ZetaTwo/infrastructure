resource "hcloud_ssh_key" "zetatwo" {
  name       = "zetatwo"
  public_key = file("${path.module}/files/zetatwo.pub")
}

resource "hcloud_server" "cluster_node" {
  count        = var.node_count
  name         = "node${count.index + 1}"
  server_type  = var.server_type
  location     = var.server_location
  image        = var.server_image
  ssh_keys     = [hcloud_ssh_key.zetatwo.id]
  firewall_ids = [hcloud_firewall.cluster_node.id]

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }
}
