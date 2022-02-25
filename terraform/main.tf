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

  machine_type = "f1-micro"

  network_interface {
    subnetwork = module.vpc.subnets_names[0] // ini karena subnetworknya custom, jakarta
    access_config {
    }
  }
}