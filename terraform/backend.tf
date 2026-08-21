terraform {
  required_version = ">= 1.10.0" # required for native S3 state locking (use_lockfile)

  backend "s3" {
    # Configured at `terraform init -backend-config=backend.hcl` time — see backend.hcl.example.
    # Left empty here so no bucket/credentials are hardcoded into version control.
  }
}
