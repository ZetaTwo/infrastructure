variable "hcloud_token" {
  description = "Hetzner Cloud API token (Read & Write). Provided via secrets.auto.tfvars, never committed."
  type        = string
  sensitive   = true
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token scoped to every zone referenced in cloudflare_zones. Provided via secrets.auto.tfvars, never committed."
  type        = string
  sensitive   = true
}

variable "cloudflare_zones" {
  description = "Cloudflare zone IDs, keyed by an arbitrary label used to reference each zone elsewhere (DNS records, Ansible inventory vars). Domain names are looked up from the Cloudflare API via data.cloudflare_zone, not stored here. e.g. { zetatwo_com = \"...\", zetatwo_dev = \"...\" }."
  type        = map(string)
}

variable "server_type" {
  description = "Hetzner Cloud server type."
  type        = string
  default     = "cpx22"
}

variable "server_location" {
  description = "Hetzner Cloud datacenter location."
  type        = string
  default     = "fsn1"
}

variable "server_image" {
  description = "Hetzner Cloud OS image. Verify current slug with `hcloud image list --type system`."
  type        = string
  default     = "ubuntu-26.04"
}
