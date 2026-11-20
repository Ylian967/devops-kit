# =============================================================================
# providers.tf : à quel daemon Docker parle OpenTofu.
#
# Même code pour les deux cibles du bloc cd-release, seule l'adresse change :
#   runner self-hosted local  docker_host = null (socket unix:///var/run/docker.sock)
#   VPS en SSH                docker_host = "ssh://deploy@vps.example.com"
#                             (TF_VAR_docker_host ; clé et known_hosts préparés avant)
# =============================================================================
provider "docker" {
  # null = valeur par défaut du provider : DOCKER_HOST s'il est défini, sinon le
  # socket local. ssh:// lance `ssh` puis `docker system dial-stdio` sur la cible :
  # il faut le client ssh ici, et le CLI docker installé sur le VPS.
  host = var.docker_host

  # Authentification à ghcr.io, seulement si un utilisateur est fourni (paquet privé).
  # Pipeline : TF_VAR_ghcr_username = github.actor, TF_VAR_ghcr_token =
  # secrets.GITHUB_TOKEN (permission packages: read). Le jeton configure le
  # provider : il n'est PAS écrit dans le state.
  dynamic "registry_auth" {
    # Condition sur l'utilisateur, pas sur le jeton : une valeur « sensitive » ne
    # peut pas décider du nombre de blocs (erreur au plan).
    for_each = var.ghcr_username == null ? [] : [1]
    content {
      address  = "ghcr.io"
      username = var.ghcr_username
      password = var.ghcr_token
    }
  }
}
