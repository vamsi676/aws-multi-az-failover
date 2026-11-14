variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block of the VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "azs" {
  description = "Exactly two Availability Zones: [active, standby]."
  type        = list(string)

  validation {
    condition     = length(var.azs) == 2
    error_message = "Provide exactly two Availability Zones."
  }
}

variable "public_subnet_cidrs" {
  description = "One public subnet CIDR per AZ, same order as var.azs."
  type        = list(string)

  validation {
    condition     = length(var.public_subnet_cidrs) == 2
    error_message = "Provide exactly two subnet CIDRs."
  }
}

variable "allowed_cidr" {
  description = "CIDR allowed to reach the NLB on port 80 (your IP, e.g. 203.0.113.10/32)."
  type        = string
  sensitive   = true

  validation {
    condition     = can(cidrhost(var.allowed_cidr, 0))
    error_message = "allowed_cidr must be a valid CIDR, e.g. 203.0.113.10/32."
  }
}
