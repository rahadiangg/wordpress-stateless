
output "container_registry" {
    value = "asia.gcr.io/${var.project_id}/${var.project_name}:latest"
    description = "Build image dan push ke reposity ini"
}