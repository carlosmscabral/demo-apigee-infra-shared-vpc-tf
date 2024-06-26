/**
 * Copyright 2023 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

locals {
  psc_subnet_region_name = { for subnet in var.psc_ingress_subnets :
    subnet.region => "${subnet.region}/${subnet.name}"
  }
  svpc_host_project_id = var.svpc_host_project_id != "" ? var.svpc_host_project_id : join("-", ["host", var.project_id])
}

module "host-project" {
  source              = "github.com/terraform-google-modules/cloud-foundation-fabric//modules/project?ref=v28.0.0"
  name                = local.svpc_host_project_id
  parent              = var.project_parent
  billing_account     = var.billing_account
  project_create      = var.project_create
  auto_create_network = false
  shared_vpc_host_config = {
    enabled          = true
    service_projects = [] # defined later
  }
  services = [
    "servicenetworking.googleapis.com"
  ]
}

module "service-project" {
  source              = "github.com/terraform-google-modules/cloud-foundation-fabric//modules/project?ref=v28.0.0"
  name                = var.project_id
  parent              = var.project_parent
  billing_account     = var.billing_account
  project_create      = var.project_create
  auto_create_network = false
  shared_vpc_service_config = {
    attach               = true
    host_project         = module.host-project.project_id
    service_identity_iam = {}
  }
  services = [
    "apigee.googleapis.com",
    "cloudkms.googleapis.com",
    "compute.googleapis.com",
    "servicenetworking.googleapis.com"
  ]
}

module "shared-vpc" {
  source          = "github.com/terraform-google-modules/cloud-foundation-fabric//modules/net-vpc?ref=v28.0.0"
  project_id      = module.host-project.project_id
  name            = var.network
  shared_vpc_host = true
  shared_vpc_service_projects = [
    module.service-project.project_id
  ]
  subnets = [
    for subnet in var.psc_ingress_subnets :
    {
      "name"                = subnet.name
      "region"              = subnet.region
      "secondary_ip_ranges" = subnet.secondary_ip_range
      "ip_cidr_range"       = subnet.ip_cidr_range
      "iam" = {
        "roles/compute.networkUser" = [
          "serviceAccount:${module.service-project.service_accounts.cloud_services}"
        ]
      }
    }
  ]
  psa_config = {
    ranges = {
      apigee-range         = var.peering_range
      apigee-support-range = var.support_range
    }
    export_routes  = true
    import_routes  = true
  }
}

module "nip-development-hostname" {
  source             = "github.com/apigee/terraform-modules/modules/nip-development-hostname"
  project_id         = module.service-project.project_id
  address_name       = "apigee-external"
  subdomain_prefixes = [for name, _ in var.apigee_envgroups : name]
}

module "apigee-x-core" {
  source              = "github.com/apigee/terraform-modules/modules/apigee-x-core"
  project_id          = module.service-project.project_id
  ax_region           = var.ax_region
  apigee_environments = var.apigee_environments
  apigee_instances    = var.apigee_instances
  apigee_envgroups = {
    for name, env_group in var.apigee_envgroups : name => {
      hostnames = concat(env_group.hostnames, ["${name}.${module.nip-development-hostname.hostname}"])
    }
  }
  network = module.shared-vpc.network.id
  billing_type = "PAYG"
}


resource "google_compute_region_network_endpoint_group" "psc_neg" {
  project               = var.project_id
  for_each              = var.apigee_instances
  name                  = "psc-neg-${each.value.region}"
  region                = each.value.region
  network               = module.shared-vpc.network.id
  subnetwork            = module.shared-vpc.subnet_self_links[local.psc_subnet_region_name[each.value.region]]
  network_endpoint_type = "PRIVATE_SERVICE_CONNECT"
  psc_target_service    = module.apigee-x-core.instance_service_attachments[each.value.region]
  lifecycle {
    create_before_destroy = true
  }
}

module "nb-psc-l7xlb" {
  source          = "github.com/apigee/terraform-modules/modules/nb-psc-l7xlb"
  project_id      = module.service-project.project_id
  name            = "apigee-xlb-psc"
  ssl_certificate = [module.nip-development-hostname.ssl_certificate]
  external_ip     = module.nip-development-hostname.ip_address
  psc_negs        = [for _, psc_neg in google_compute_region_network_endpoint_group.psc_neg : psc_neg.id]
}