#!/usr/bin/env bash
# =============================================================================
# backup.sh : sauvegarde la base PostgreSQL d'un environnement avec pg_dump.
#
#     deploy/backup.sh <staging|production>
#
# Produit $DEPLOY_DIR/backups/<env>-AAAAMMJJ-HHMMSS.sql.gz et ne garde que les
# BACKUP_KEEP plus récentes (défaut 14) : c'est la rotation.
# deploy.sh l'appelle avant chaque déploiement de production.
#
# Planifier (cron de l'utilisateur de déploiement, chaque nuit à 3 h) :
#   0 3 * * * /opt/monapp/production/deploy/backup.sh production >> /opt/monapp/production/backups/backup.log 2>&1
#
# RESTAURER (à essayer AVANT d'en avoir besoin : une sauvegarde jamais restaurée
# n'est pas une sauvegarde) :
#   export IMAGE_TAG=$(cat .deployed-tag)
#   gunzip -c backups/production-XXXX.sql.gz | docker compose -f compose.prod.yaml exec -T db \
#     sh -c 'psql -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
#
# Limite : les sauvegardes restent sur le même disque que la base. Copiez-les
# ailleurs (autre machine, stockage objet) pour survivre à la perte du serveur.
# =============================================================================
set -euo pipefail

ENV_NAME="${1:-}"
[[ "$ENV_NAME" =~ ^(staging|production)$ ]] || { echo "Usage : deploy/backup.sh <staging|production>" >&2; exit 2; }

DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
BACKUP_DIR="${BACKUP_DIR:-$DEPLOY_DIR/backups}"
KEEP="${BACKUP_KEEP:-14}"
cd "$DEPLOY_DIR"

# compose.prod.yaml exige IMAGE_TAG (même pour un exec) : on prend celui qui tourne.
export IMAGE_TAG="${IMAGE_TAG:-$(cat .deployed-tag 2>/dev/null || true)}"
[ -n "$IMAGE_TAG" ] || { echo "Aucune version déployée (.deployed-tag absent) : rien à sauvegarder" >&2; exit 1; }

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"                  # une sauvegarde contient toutes les données : pas lisible des autres
FINAL="$BACKUP_DIR/$ENV_NAME-$(date +%Y%m%d-%H%M%S).sql.gz"
PARTIAL="$FINAL.partial"
# Un fichier incomplet ne doit jamais passer pour une sauvegarde : supprimé en
# sortie quoi qu'il arrive (il n'existe plus si tout s'est bien passé).
trap 'rm -f "$PARTIAL"' EXIT

echo "==> Sauvegarde de $ENV_NAME vers $FINAL"
# -T : pas de terminal (script, cron). Les identifiants sont lus DANS le
# conteneur db (ses variables POSTGRES_*), le mot de passe ne passe pas ici.
# --clean --if-exists : la restauration remplace les objets existants.
docker compose -f compose.prod.yaml exec -T db \
  sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists' | gzip > "$PARTIAL"

# pipefail fait déjà échouer si pg_dump échoue ; on refuse aussi un dump vide.
[ "$(gunzip -c "$PARTIAL" | head -c 1 | wc -c)" -eq 1 ] || { echo "Sauvegarde vide : refusée" >&2; exit 1; }
mv "$PARTIAL" "$FINAL"                   # le vrai nom seulement une fois complet

# Rotation : on liste du plus récent au plus ancien et on supprime au-delà de KEEP.
# (Noms sans espaces, générés ci-dessus : ls est sûr ici.)
# shellcheck disable=SC2012
ls -1t "$BACKUP_DIR/$ENV_NAME"-*.sql.gz | tail -n +"$((KEEP + 1))" | xargs -r rm -f --

echo "==> Terminé : $(ls -1 "$BACKUP_DIR/$ENV_NAME"-*.sql.gz | wc -l) sauvegarde(s) de $ENV_NAME conservée(s)"
