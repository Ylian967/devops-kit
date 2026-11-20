# =============================================================================
# versions.tf : version d'OpenTofu, providers utilisés et backend du state.
#
# Après tout changement de provider (ajout, version) : régénérer le lock file
# pour toutes les plateformes (poste Linux/macOS/Windows, runner linux_amd64) :
#   tofu init -upgrade
#   tofu providers lock -platform=linux_amd64 -platform=linux_arm64 \
#     -platform=darwin_amd64 -platform=darwin_arm64 -platform=windows_amd64
# .terraform.lock.hcl est VERSIONNÉ (comme package-lock.json) ; .terraform/ ne l'est pas.
# =============================================================================
terraform {
  # Le code ne sert qu'avec OpenTofu : on n'essaie pas de rester compatible
  # Terraform. 1.8 : variables utilisables dans le bloc encryption (cible VPS).
  required_version = ">= 1.8.0"

  required_providers {
    # Pilote un daemon Docker (socket local ou ssh://) : réseaux, volumes,
    # images et conteneurs, comme un provider cloud pilote des VM.
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 4.7" # 4.7.x et 4.8+, jamais 5.0 (changements cassants possibles)
    }
    # Génère le mot de passe PostgreSQL du staging (il vit dans le state).
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }

  # State local, HORS du dépôt : le chemin n'est pas écrit ici, il est donné à l'init.
  #   tofu init -backend-config="path=$DEPLOY_DIR/terraform.tfstate"
  # Sans -backend-config, le state serait écrit dans infra/terraform.tfstate
  # (ignoré par Git, mais perdu au prochain clone : à éviter hors essais).
  # Cible VPS pilotée depuis un runner GitHub (machine jetable) : backend
  # distant chiffré à la place, voir references/cibles.md du bloc iac.
  backend "local" {}
}
