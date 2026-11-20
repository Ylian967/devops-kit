# =============================================================================
# main.tf : l'environnement staging, décrit en code (provider kreuzwerker/docker).
#
#   Ressource OpenTofu          Objet Docker (<p> = <project>-<environment>)
#   docker_network.default      réseau   <p>_default   (même nom que Compose : le
#                                                       monitoring s'y branche pareil)
#   docker_volume.pgdata        volume   <p>_pgdata    (idem : un volume Compose
#                                                       existant peut être importé)
#   docker_container.db         <p>-db   alias réseau « db », aucun port publié
#   docker_container.app        <p>-app  alias « app », publié sur publish_ip:published_port
#
# UN SEUL outil par environnement : ce staging n'est plus lancé par
# `docker compose -p <p> up`. Garde-fou gratuit : Compose refuse d'utiliser un
# réseau <p>_default qu'il n'a pas créé, et OpenTofu refuse d'en créer un qui
# existe déjà. La production, elle, reste en Compose (deploy/deploy.sh).
# Voir references/cibles.md du bloc iac (partage des rôles avec cd-release).
# =============================================================================

locals {
  prefix = "${var.project}-${var.environment}"
  image  = "${var.image_repository}:${var.image_tag}"

  db_password = random_password.db.result # vit dans le state, nulle part ailleurs
  db_user     = "app"                     # mêmes valeurs que POSTGRES_USER / POSTGRES_DB du .env
  db_name     = "app"
}

# ---------- Réseau et stockage ----------------------------------------------

resource "docker_network" "default" {
  name = "${local.prefix}_default"
}

resource "docker_volume" "pgdata" {
  name = "${local.prefix}_pgdata"

  lifecycle {
    # Un volume repris de Compose (tofu import) porte des labels com.docker.compose.*.
    # Les labels d'un volume ne se modifient pas : sans cette ligne, le plan
    # voudrait le DÉTRUIRE et le recréer (= perte des données).
    ignore_changes = [labels]
    # Production, ou staging dont les données comptent : décommenter. Tout plan
    # qui détruit le volume échoue alors (y compris tofu destroy).
    # prevent_destroy = true
  }
}

# PostgreSQL ne lit POSTGRES_PASSWORD qu'à l'initialisation d'un volume VIDE.
# Volume repris de Compose : on IMPORTE son mot de passe d'origine au lieu d'en
# tirer un nouveau (sinon l'application ne se connecte plus) :
#   tofu import random_password.db "$(sed -n 's/^POSTGRES_PASSWORD=//p' "$DEPLOY_DIR/.env")"
resource "random_password" "db" {
  length  = 32
  special = false # le mot de passe finit dans une URL (DATABASE_URL) : pas de @ : / #

  lifecycle {
    # Un mot de passe importé a sa propre longueur et est noté « special = true » :
    # sans cette ligne, le plan voudrait en tirer un nouveau (= base inaccessible).
    ignore_changes = [length, special]
  }
}

# ---------- Images -------------------------------------------------------------
# docker_image tire l'image sur le daemon CIBLE (le VPS en ssh://, pas le runner).
# keep_locally : un destroy ou un changement de version ne supprime pas l'ancienne
# image, ce qui rend le retour arrière immédiat. Le ménage (docker image prune)
# reste au bloc cd-release.

resource "docker_image" "db" {
  name         = "docker.io/library/postgres:17-alpine" # même version majeure qu'en dev, CI et production
  keep_locally = true
}

resource "docker_image" "app" {
  name         = local.image
  keep_locally = true
}

# ---------- Conteneurs ---------------------------------------------------------

resource "docker_container" "db" {
  name    = "${local.prefix}-db"
  image   = docker_image.db.image_id # l'identifiant sha256 : une nouvelle image = remplacement visible dans le plan
  restart = "unless-stopped"         # redémarre après un reboot de la machine, sauf arrêt volontaire

  env = [
    "POSTGRES_USER=${local.db_user}",
    "POSTGRES_PASSWORD=${local.db_password}", # en clair dans le state : d'où un state jamais versionné
    "POSTGRES_DB=${local.db_name}",
  ]

  volumes {
    volume_name    = docker_volume.pgdata.name
    container_path = "/var/lib/postgresql/data"
  }

  # Aucun bloc ports : la base n'est joignable que sur le réseau privé, sous le nom « db ».
  networks_advanced {
    name    = docker_network.default.id
    aliases = ["db"] # même nom que le service Compose : DATABASE_URL identique partout
  }

  healthcheck {
    test     = ["CMD-SHELL", "pg_isready -U ${local.db_user} -d ${local.db_name}"]
    interval = "5s"
    timeout  = "3s"
    retries  = 10
  }

  # apply attend que la base soit « healthy » avant de passer à l'application
  # (l'équivalent de depends_on: condition: service_healthy dans Compose).
  wait         = true
  wait_timeout = 120
}

resource "docker_container" "app" {
  name    = "${local.prefix}-app"
  image   = docker_image.app.image_id
  restart = "unless-stopped"

  env = [
    "PORT=${var.app_port}",
    "APP_ENV=${var.environment}",
    "APP_VERSION=${var.image_tag}", # renvoyé par /health : le smoke test vérifie la version
    "DATABASE_URL=postgres://${local.db_user}:${local.db_password}@db:5432/${local.db_name}",
  ]

  networks_advanced {
    name    = docker_network.default.id
    aliases = ["app"] # nom utilisé par un proxy (proxy_pass http://app:<port>) ou par blackbox
  }

  ports {
    internal = var.app_port
    external = var.published_port
    ip       = var.publish_ip
  }

  # Même sonde que le HEALTHCHECK du Dockerfile, répétée ici : « wait » en a
  # besoin, et le plan montre la sonde réellement appliquée.
  healthcheck {
    test         = var.app_healthcheck
    interval     = "5s"
    timeout      = "3s"
    retries      = 10
    start_period = "10s" # Java : 60s (démarrage de la JVM)
  }

  # apply échoue si l'application n'est pas « healthy » à temps : un déploiement
  # cassé (mauvais DATABASE_URL, migration ratée) rend le job rouge.
  wait         = true
  wait_timeout = 120

  depends_on = [docker_container.db]
}
