locals {
  common_tags = {
    Project     = var.project
    Environment = "internship"
    ManagedBy   = "terraform"
  }
}
