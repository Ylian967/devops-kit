# =============================================================================
# outputs.tf : affichés à la fin d'un apply, relus par les scripts :
#   tofu output              tofu output -raw health_url
# =============================================================================

output "health_url" {
  description = "Route lue par le smoke test, DEPUIS la machine cible (127.0.0.1 par défaut)."
  value       = "http://${var.publish_ip}:${var.published_port}/health"
}

output "image_tag" {
  description = "Version déployée. iac.yml la relit pour planifier une PR sans changer de version."
  value       = var.image_tag
}

output "containers" {
  description = "Noms des conteneurs gérés par OpenTofu (à ne jamais toucher avec docker compose)."
  value       = [docker_container.db.name, docker_container.app.name]
}

output "network" {
  description = "Réseau Docker de l'environnement (le monitoring s'y branche)."
  value       = docker_network.default.name
}
