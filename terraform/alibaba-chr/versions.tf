terraform {
  required_version = ">= 1.5"

  required_providers {
    alicloud = {
      source  = "aliyun/alicloud"
      version = "~> 1.240"
    }
  }
}

provider "alicloud" {
  # The provider does NOT auto-discover the CLI's shared config the way some
  # others do; the profile from `aliyun configure` must be named explicitly.
  profile = var.profile
  region  = var.region
}
