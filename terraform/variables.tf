variable "hcloud_token" {
  description = "Hetzner Cloud API token (Read & Write). Provided via secrets.auto.tfvars, never committed."
  type        = string
  sensitive   = true
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token scoped to the apps_zone_id and admin_zone_id zones. Provided via secrets.auto.tfvars, never committed."
  type        = string
  sensitive   = true
}

variable "apps_zone_id" {
  description = "Cloudflare zone ID for the domain hosting hobby apps, e.g. demo.<domain>."
  type        = string
}

variable "admin_zone_id" {
  description = "Cloudflare zone ID for the domain hosting admin/infra surfaces, e.g. admin.<domain>."
  type        = string
}

variable "server_type" {
  description = "Hetzner Cloud server type."
  type        = string
  default     = "cpx31"
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
