#!/usr/bin/env bash
# =============================================================================
# deploy.sh : met un environnement (staging ou production) à une version donnée,
# vérifie qu'elle répond, et revient tout seul à la version précédente sinon.
#
#     deploy/deploy.sh <staging|production> <tag>
#       <tag> = SHA court (7 caractères hexadécimaux) d'une image publiée.
#
# Le script vit dans $DEPLOY_DIR/deploy/ ; $DEPLOY_DIR contient aussi
# compose.prod.yaml, .env (secrets, jamais versionné), certs/ et backups/.
# Le pipeline (release.yml) l'appelle ; on peut aussi l'appeler à la main sur le
# serveur, par exemple pour un rollback d'urgence : deploy/deploy.sh production a1b2c3d
#
# Déroulé :
#   1. contrôles (.env présent, APP_ENV et nom de projet cohérents avec <env>) ;
#   2. production seulement : sauvegarde de la base (deploy/backup.sh) ;
#   3. migrations éventuelles (MIGRATE_CMD), puis `docker compose up --wait` ;
#   4. rechargement du proxy, smoke test sur /health avec la version attendue ;
#   5. échec à l'étape 3 ou 4 : redéploiement de .previous-tag, et sortie en erreur
#      (le job reste rouge : un incident a eu lieu, même si le service est rétabli).
#
# Variables (environnement du shell, sinon lues dans .env) :
#   SMOKE_URL        URL de /health à tester (défaut https://localhost:<HTTPS_PORT>/health)
#   SMOKE_CURL_OPTS  options curl du smoke test (ex. --cacert certs/fullchain.pem)
#   PULL_POLICY      always (défaut) : tirer les images ; missing : seulement si
#                    absentes en local (images construites sur la machine, tests)
#   MIGRATE_CMD      commande de migration lancée dans un conteneur `app` jetable
#   SKIP_BACKUP=1    ne pas sauvegarder avant un déploiement de production
# =============================================================================
set -euo pipefail

ENV_NAME="${1:-}"
TAG="${2:-}"

# ---------- 1. Contrôles ------------------------------------------------------
# Les deux arguments sont validés : ils finissent dans des commandes docker.
if [[ ! "$ENV_NAME" =~ ^(staging|production)$ ]] || [[ ! "$TAG" =~ ^[0-9a-f]{7}$ ]]; then
  echo "Usage : deploy/deploy.sh <staging|production> <tag>   (tag = SHA court, 7 caractères)" >&2
  exit 2
fi

# DEPLOY_DIR = le dossier parent de deploy/ (là où sont compose.prod.yaml et .env)
DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$DEPLOY_DIR"

[ -f compose.prod.yaml ] || { echo "compose.prod.yaml absent de $DEPLOY_DIR" >&2; exit 1; }
[ -f .env ] || { echo ".env absent de $DEPLOY_DIR : il se crée à la main (voir docs/DEPLOIEMENT.md)" >&2; exit 1; }

# Lit une valeur du .env (format CLE=valeur, sans guillemets). La variable du
# shell, si elle est définie, l'emporte (comme pour docker compose).
env_val() {
  local v="${!1:-}"
  [ -n "$v" ] || v="$(sed -n "s/^$1=//p" .env | tail -n1)"
  printf '%s' "$v"
}

# Garde-fou : on ne déploie pas « production » dans le dossier du staging.
if [ "$(env_val APP_ENV)" != "$ENV_NAME" ]; then
  echo "APP_ENV du .env ($(env_val APP_ENV)) différent de '$ENV_NAME' : mauvais dossier ?" >&2
  exit 1
fi
# Le nom de projet Compose isole les environnements d'une même machine
# (conteneurs, volume pgdata, réseau <projet>_default).
if [[ "$(env_val COMPOSE_PROJECT_NAME)" != *-"$ENV_NAME" ]]; then
  echo "COMPOSE_PROJECT_NAME doit être défini dans .env et finir par -$ENV_NAME" >&2
  exit 1
fi

HTTPS_PORT="$(env_val HTTPS_PORT)"
SMOKE_URL="$(env_val SMOKE_URL)"
SMOKE_URL="${SMOKE_URL:-https://localhost:${HTTPS_PORT:-443}/health}"
export SMOKE_CURL_OPTS
SMOKE_CURL_OPTS="$(env_val SMOKE_CURL_OPTS)"
PULL_POLICY="$(env_val PULL_POLICY)"
MIGRATE_CMD="$(env_val MIGRATE_CMD)"

# Le fichier compose est toujours celui de DEPLOY_DIR ; il lit .env tout seul.
dc() { docker compose -f compose.prod.yaml "$@"; }
has_service() { dc config --services | grep -qx "$1"; }

# Met en ligne la version $1 et vérifie qu'elle répond. Code retour 0 = sain.
release() {
  export IMAGE_TAG="$1"     # lu par compose.prod.yaml : ${IMAGE_TAG}
  if [ -n "$MIGRATE_CMD" ]; then
    echo "==> Migrations : $MIGRATE_CMD"
    has_service db && dc up -d --wait db
    # shellcheck disable=SC2086  # découpage voulu : MIGRATE_CMD est une commande et ses arguments
    dc run --rm --no-deps app $MIGRATE_CMD || return 1
  fi
  echo "==> docker compose up ($IMAGE_TAG)"
  # --pull : always tire les images (correctifs de nginx, postgres) ; missing
  # n'appelle le registre que si l'image manque. --wait : attend que les
  # healthchecks soient verts, échoue sinon. Seuls les conteneurs dont l'image
  # ou la configuration change sont recréés.
  dc up -d --pull "${PULL_POLICY:-always}" --remove-orphans --wait --wait-timeout 180 || return 1
  # Nginx résout le nom `app` au démarrage : après recréation du conteneur app
  # (nouvelle IP), on le recharge, sans coupure, après avoir testé la config.
  if has_service proxy; then
    dc exec -T proxy nginx -t -q && dc exec -T proxy nginx -s reload || return 1
  fi
  "$DEPLOY_DIR/deploy/smoke-test.sh" "$SMOKE_URL" "$IMAGE_TAG"
}

echo "==> $ENV_NAME : déploiement de $TAG dans $DEPLOY_DIR"

# ---------- 2. Sauvegarde (production, sauf premier déploiement) ------------
# Un rollback revient sur le CODE, pas sur les DONNÉES : la sauvegarde prise
# juste avant est le seul retour possible si la nouvelle version abîme la base.
if [ "$ENV_NAME" = production ] && [ -f .deployed-tag ] && [ "${SKIP_BACKUP:-0}" != 1 ] && has_service db; then
  IMAGE_TAG="$(cat .deployed-tag)" "$DEPLOY_DIR/deploy/backup.sh" "$ENV_NAME"
fi

# ---------- 3 et 4. Mise en ligne -------------------------------------------
# On mémorise la version qui tourne AVANT de la remplacer : c'est la cible du
# rollback. Redéployer le même tag ne touche pas à .previous-tag.
current="$(cat .deployed-tag 2>/dev/null || true)"
before_previous="$(cat .previous-tag 2>/dev/null || true)"   # rétabli si on revient en arrière
if [ -n "$current" ] && [ "$current" != "$TAG" ]; then
  echo "$current" > .previous-tag
fi

if release "$TAG"; then
  echo "$TAG" > .deployed-tag
  # Supprime seulement les images sans tag : les versions précédentes restent
  # en cache, un rollback n'a rien à télécharger.
  docker image prune -f >/dev/null
  echo "==> $ENV_NAME : $TAG en ligne (précédente : $(cat .previous-tag 2>/dev/null || echo aucune))"
  exit 0
fi

# ---------- 5. Rollback automatique -----------------------------------------
previous="$(cat .previous-tag 2>/dev/null || true)"
if [ -z "$previous" ] || [ "$previous" = "$TAG" ]; then
  echo "ÉCHEC du déploiement de $TAG et aucune version précédente connue : intervention manuelle." >&2
  dc ps -a >&2 || true
  exit 1
fi
echo "ÉCHEC du déploiement de $TAG : retour automatique à $previous" >&2
dc logs --tail 50 app >&2 || true      # les logs de la version cassée, pour le diagnostic
MIGRATE_CMD=""                          # on ne rejoue pas les migrations de la version cassée
if release "$previous"; then
  echo "$previous" > .deployed-tag
  # La version cassée n'a jamais été en ligne : l'historique redevient celui d'avant.
  if [ -n "$before_previous" ]; then echo "$before_previous" > .previous-tag; else rm -f .previous-tag; fi
  echo "Rollback effectué : $ENV_NAME est revenu à $previous. Le déploiement de $TAG reste en ÉCHEC." >&2
else
  echo "Le rollback vers $previous a lui aussi échoué : intervention manuelle immédiate." >&2
fi
exit 1
