variable "hcloud_token" {
  description = "Hetzner Cloud API token (Read & Write). Provided via secrets.auto.tfvars, never committed."
  type        = string
  sensitive   = true
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token scoped to the apps_domain and admin_domain zones. Provided via secrets.auto.tfvars, never committed."
  type        = string
  sensitive   = true
}

variable "apps_domain" {
  description = "Domain hosting hobby apps, e.g. demo.<apps_domain>."
  type        = string
  default     = "zeta-two.com"
}

variable "admin_domain" {
  description = "Domain hosting admin/infra surfaces, e.g. admin.<admin_domain>."
  type        = string
  default     = "zetatwo.dev"
}

variable "apps_zone_id" {
  description = "Cloudflare zone ID for apps_domain."
  type        = string
}

variable "admin_zone_id" {
  description = "Cloudflare zone ID for admin_domain."
  type        = string
}

variable "server_type" {
  description = "Hetzner Cloud server type."
  type        = string
  default     = "cx22"
}

variable "server_location" {
  description = "Hetzner Cloud datacenter location."
  type        = string
  default     = "fsn1"
}

variable "server_image" {
  description = "Hetzner Cloud OS image. Verify current slug with `hcloud image list --type system`."
  type        = string
  default     = "ubuntu-24.04"
}
