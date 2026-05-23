###############################################################################
# Variables
###############################################################################

variable "project" {
  description = "Short project name – used as a prefix for every resource"
  type        = string
  default     = "quickstart"
}

variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "private_subnet_cidr" {
  description = "CIDR block for the private subnet (engine + workers)"
  type        = string
  default     = "10.0.1.0/24"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet (API gateway)"
  type        = string
  default     = "10.0.0.0/24"
}

variable "ssh_allowed_cidr" {
  description = "CIDR from which SSH to the gateway VM is allowed (your IP)"
  type        = string
  default     = "0.0.0.0/0" # ← tighten this to your IP in production
}

variable "public_key_path" {
  description = "Local path to the SSH public key used for EC2 key pair"
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

# ── Instance types ──────────────────────────────────────────────────────────
# All default to t3.small (free-tier eligible or very cheap).
# Bump inference to t3.medium / t3.large if Gemma 270 M is slow.

variable "engine_instance_type" {
  description = "EC2 instance type for the iii engine VM"
  type        = string
  default     = "t3.small"
}

variable "inference_instance_type" {
  description = "EC2 instance type for the Python inference-worker VM"
  type        = string
  default     = "t3.medium" # model loading needs a bit more RAM
}

variable "caller_instance_type" {
  description = "EC2 instance type for the TypeScript caller-worker VM"
  type        = string
  default     = "t3.small"
}

variable "gateway_instance_type" {
  description = "EC2 instance type for the Nginx API-gateway VM"
  type        = string
  default     = "t3.micro"
}
