# =============================================================================
# variables.tf : les entrées. Valeurs par défaut ici (rien de secret), surcharges
# dans terraform.tfvars (poste, non versionné), -var, ou TF_VAR_<nom> (CI).
# Modèle à ADAPTER : project, image_repository, ports, healthcheck.
# =============================================================================

variable "project" {
  description = "Nom du dépôt en minuscules : préfixe des ressources (<project>-<environment>)."
  type        = string
  default     = "monapp" # REMPLACER par le nom du dépôt

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*$", var.project))
    error_message = "project : minuscules, chiffres et tirets seulement (noms Docker et ghcr.io)."
  }
}

variable "environment" {
  description = "Environnement décrit : préfixe des noms et valeur de APP_ENV."
  type        = string
  default     = "staging"

  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "environment : staging ou production (conventions devops-kit)."
  }
}

variable "image_repository" {
  description = "Image de l'application, sans tag (publiée par release.yml)."
  type        = string
  default     = "ghcr.io/proprietaire/monapp" # REMPLACER : ghcr.io/<owner>/<repo> en minuscules

  validation {
    condition     = var.image_repository == lower(var.image_repository)
    error_message = "image_repository doit être en minuscules (ghcr.io refuse les majuscules)."
  }
}

variable "image_tag" {
  description = "Version à déployer : SHA court du commit (IMAGE_TAG). Pas de défaut : on choisit toujours."
  type        = string

  validation {
    # Jamais latest : le plan doit dire QUELLE version tourne, et un rollback
    # = rejouer l'apply avec l'ancien SHA.
    condition     = can(regex("^[0-9a-f]{7}$", var.image_tag))
    error_message = "image_tag doit être un SHA court de 7 caractères hexadécimaux (git rev-parse --short=7 HEAD)."
  }
}

variable "app_port" {
  description = "Port d'écoute de l'application DANS le conteneur (Node 3000, Java/Rust 8080, Phoenix 4000)."
  type        = number
  default     = 3000
}

variable "published_port" {
  description = "Port publié sur la machine cible pour joindre le staging (smoke test, proxy)."
  type        = number
  default     = 8081

  validation {
    condition     = var.published_port >= 1024 && var.published_port <= 65535
    error_message = "published_port : port non privilégié (1024-65535)."
  }
}

variable "publish_ip" {
  description = "Adresse d'écoute du port publié. 127.0.0.1 = joignable seulement depuis la machine (proxy, smoke test local)."
  type        = string
  default     = "127.0.0.1" # 0.0.0.0 l'ouvrirait à Internet, et Docker passe AVANT le pare-feu ufw
}

variable "app_healthcheck" {
  description = "Commande de healthcheck de l'application (même sonde que le HEALTHCHECK du Dockerfile)."
  type        = list(string)
  # Node : fetch() intégré, ni curl ni wget nécessaires. Autres stacks : references/stacks.md.
  default = ["CMD", "node", "-e", "fetch('http://127.0.0.1:'+(process.env.PORT||3000)+'/health').then(r=>process.exit(r.ok?0:1),()=>process.exit(1))"]
}

variable "docker_host" {
  description = "Daemon Docker cible. null = socket local ; ssh://deploy@vps pour un VPS."
  type        = string
  default     = null
}

variable "ghcr_username" {
  description = "Utilisateur ghcr.io (github.actor dans le pipeline). Inutile si le paquet est public."
  type        = string
  default     = null
}

variable "ghcr_token" {
  description = "Jeton de lecture ghcr.io (GITHUB_TOKEN dans le pipeline). null = paquet public ou image déjà présente."
  type        = string
  default     = null
  sensitive   = true
}
