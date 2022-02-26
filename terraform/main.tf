terraform {
  required_providers {
    google = {
      source = "hashicorp/google"
      version = "4.11.0"
    }
  }
}

variable "region" {
}
variable "project_id" {
}
variable "project_name" {
}
variable "db_user" {
}
variable "db_pass" {
}

provider "google" {
  region = var.region
  project = var.project_id
}

provider "google-beta" {
  region = var.region
  project = var.project_id
}

// define random
// untuk keperluan CloudSQL, karena nama yang sudah dibuat gak bisa dibuatlagi selama satu minggu
resource "random_id" "suffix" {
  byte_length = 4
}

// setup vpc
module "vpc" {
  source  = "terraform-google-modules/network/google"
  version = "5.0.0"

  project_id   = var.project_id
  network_name = "vpc-${var.project_name}"
  routing_mode = "REGIONAL"

  subnets = [
      {
          subnet_name           = "jakarta"
          subnet_ip             = "10.10.0.0/24"
          subnet_region         = var.region
      }
  ]

  firewall_rules = [
      {
          name                    = "allow-ssh-ingress"
          description             = null
          direction               = "INGRESS"
          priority                = null
          ranges                  = ["0.0.0.0/0"]
          source_tags             = null
          target_tags             = null
          allow = [{
              protocol = "tcp"
              ports    = ["22"]
          }]
          deny = []
      },
      {
          name                    = "allow-http-ingress"
          description             = null
          direction               = "INGRESS"
          priority                = null
          ranges                  = ["0.0.0.0/0"]
          source_tags             = null
          target_tags             = ["allow-http"]
          allow = [{
              protocol = "tcp"
              ports    = ["80"]
          }]
          deny = []
      },
      {
          name                    = "allow-health-check"
          description             = null
          direction               = "INGRESS"
          priority                = null
          ranges                  = ["35.191.0.0/16", "130.211.0.0/22"]
          source_tags             = null
          target_tags             = ["allow-hc"]
          allow = [{
              protocol = "tcp"
              ports    = []
          }]
          deny = []
      }
  ]
}

// VPC Peering untuk konek database internal network
resource "google_compute_global_address" "private_ip_address" {
  provider = google-beta

  name          = "private-ip-address"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = module.vpc.network_id
}

resource "google_service_networking_connection" "private_vpc_connection" {
  provider = google-beta

  network                 = module.vpc.network_id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_address.name]
}

// setup cloud storage
resource "google_storage_bucket" "bucket" {
  name = "${var.project_name}-static"
  force_destroy = true // untuk ujicoba saya buat true
  uniform_bucket_level_access = false
  storage_class = "STANDARD"
  location = var.region
}

// setup cloudSQL

resource "google_sql_user" "sql_user" {
  name     = var.db_user
  instance = google_sql_database_instance.master.name
  password = var.db_pass
}

resource "google_sql_database" "db" {
  name     = var.project_name
  instance = google_sql_database_instance.master.name
}

resource "google_sql_database_instance" "master" {
  provider = google-beta
  depends_on = [google_service_networking_connection.private_vpc_connection]

  name = "master-${var.project_name}-${random_id.suffix.hex}"
  region = var.region
  database_version = "MYSQL_8_0"

  settings {
    tier = "db-f1-micro"
    availability_type = "REGIONAL"

    ip_configuration {
      ipv4_enabled = true
      private_network = module.vpc.network_id
    }

    location_preference {
      zone = "${var.region}-a"
    }

    backup_configuration {
      enabled = true
      binary_log_enabled = true
      # location = "asia"
    }
  }
}

// setup cloudsql replica
resource "google_sql_database_instance" "replica_id" {

  provider = google-beta
  depends_on = [google_service_networking_connection.private_vpc_connection]

  name                 = "replica-${var.project_name}-${random_id.suffix.hex}"
  master_instance_name = google_sql_database_instance.master.name
  region               = "asia-southeast2"
  database_version     = "MYSQL_8_0"
  deletion_protection  = false

  replica_configuration {
    failover_target = false
  }

  settings {
    tier              = "db-f1-micro"
    availability_type = "ZONAL"
    ip_configuration {
      ipv4_enabled    = false
      private_network = module.vpc.network_id
    }

    location_preference {
      zone = "${var.region}-c"
    }
  }
}


// define containernya
module "gce-container" {
  source  = "terraform-google-modules/container-vm/google"
  version = "3.0.0"

  container = {
    image = "asia.gcr.io/${var.project_id}/${var.project_name}:latest"
    env = [
      {
        name = "DB_NAME"
        value = google_sql_database.db.name
      },
      {
        name = "DB_USER"
        value = google_sql_user.sql_user.name
      },
      {
        name = "DB_PASSWORD"
        value = google_sql_user.sql_user.password
      },
      {
        name = "DB_HOST"
        value = google_sql_database_instance.master.private_ip_address
      }
    ]
  }

  restart_policy = "Always"
}


// setup instance template
resource "google_compute_instance_template" "template" {
  name = "${var.project_name}-template"
  description = "Ini template untuk run containernya"

  tags = ["allow-hc", "allow-http"]
  metadata = {
      gce-container-declaration = module.gce-container.metadata_value
      google-logging-enabled    = "true"
      google-monitoring-enabled = "true"
  }

  disk {
    source_image = module.gce-container.source_image
  }

  machine_type = "g1-small"

  network_interface {
    subnetwork = module.vpc.subnets_names[0] // ini karena subnetworknya custom, jakarta
    access_config {
    }
  }
    service_account {
      scopes = [
        "userinfo-email",
        "cloud-platform"
      ]
  }
}

// Buat health check
resource "google_compute_health_check" "autohealing" {
  name                = "autohealing-health-check"
  check_interval_sec  = 10
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3

  http_health_check {
    request_path = "/"
    port         = 80
  }
}


# // Buat instance group & autoscale regional
resource "google_compute_region_instance_group_manager" "app" {
  name = "ig-${var.project_name}"

  base_instance_name         = var.project_name
  region                     = var.region
  distribution_policy_zones  = ["${var.region}-a", "${var.region}-b", "${var.region}-c"]

  version {
    instance_template = google_compute_instance_template.template.self_link
  }

  target_pools = []
  target_size  = 1 // minimal running

  named_port {
    name = "http"
    port = 80
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.autohealing.self_link
    initial_delay_sec = 300
  }
}

resource "google_compute_region_autoscaler" "autoscaler" {
  name   = "${var.project_name}-autoscaler"
  target = google_compute_region_instance_group_manager.app.id

  autoscaling_policy {
    max_replicas    = 2
    min_replicas    = 1
    cooldown_period = 60

    cpu_utilization {
      target = 0.7
    }
  }
}



// Static IP address untuk load balancer
resource "google_compute_global_address" "address" {
  name = "static-ip-${var.project_name}"
}


// setup load balancer
module "lb-http" {
  source  = "GoogleCloudPlatform/lb-http/google"
  version = "6.2.0"
  
  project = var.project_id
  name              = "${var.project_name}-lb"
  target_tags       = ["allow-hc"]

  ssl               = true
  managed_ssl_certificate_domains  = ["wp.rahadian.dev"]
  use_ssl_certificates = false
  create_address = false
  address = google_compute_global_address.address.self_link

  # http_forward = false
  
  backends = {
    default = {
      description                     = null
      protocol                        = "HTTP"
      port                            = 80
      port_name                       = "http"
      timeout_sec                     = 10
      connection_draining_timeout_sec = null
      enable_cdn                      = false
      security_policy                 = null
      session_affinity                = null
      affinity_cookie_ttl_sec         = null
      custom_request_headers          = null
      custom_response_headers         = null

      enable_cdn                      = true

      health_check = {
        check_interval_sec  = 10
        timeout_sec         = 5
        healthy_threshold   = 2
        unhealthy_threshold = 3
        request_path        = "/"
        port                = 80
        host                = null
        logging             = null
      }

      log_config = {
        enable      = true
        sample_rate = 1.0
      }

      groups = [
        { 
          group                        = google_compute_region_instance_group_manager.app.instance_group
          balancing_mode               = null
          capacity_scaler              = null
          description                  = null
          max_connections              = null
          max_connections_per_instance = null
          max_connections_per_endpoint = null
          max_rate                     = null
          max_rate_per_instance        = null
          max_rate_per_endpoint        = null
          max_utilization              = null
        }
      ]

      iap_config = {
        enable               = false
        oauth2_client_id     = null
        oauth2_client_secret = null
      }
    }
  }

}