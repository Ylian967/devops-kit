#!/usr/bin/env bash
# =============================================================================
# smoke-test.sh : « la version que je viens de déployer répond-elle vraiment ? »
#
#     deploy/smoke-test.sh <url-de-/health> [version-attendue]
#
# Réussit quand /health répond 200 avec "status":"ok" et, si elle est fournie,
# "version":"<version-attendue>". Vérifier la version évite un faux vert :
# l'ANCIENNE version qui répond encore pendant que la nouvelle démarre.
# (Convention devops-kit : /health renvoie 503 si la base est injoignable, donc
# un 200 suffit pour la base ; "db":"none" est accepté pour un projet sans base.)
#
# Variables :
#   SMOKE_RETRIES   nombre d'essais (défaut 20)
#   SMOKE_DELAY     secondes entre deux essais (défaut 3)
#   SMOKE_CURL_OPTS options curl en plus, ex. "--cacert certs/fullchain.pem" pour
#                   VÉRIFIER un certificat auto-signé (préférer à -k, qui accepte
#                   n'importe quel certificat, y compris celui d'un imposteur).
# Dépendance : curl (pas de jq : un grep suffit sur une réponse aussi courte).
# =============================================================================
set -euo pipefail

URL="${1:?Usage : deploy/smoke-test.sh <url-de-/health> [version-attendue]}"
EXPECTED="${2:-}"
RETRIES="${SMOKE_RETRIES:-20}"
DELAY="${SMOKE_DELAY:-3}"
# shellcheck disable=SC2206  # découpage voulu : une liste d'options curl
CURL_OPTS=(${SMOKE_CURL_OPTS:-})

body=""
for i in $(seq 1 "$RETRIES"); do
  # -f : un code HTTP >= 400 (503 « degraded », 502 du proxy) est un échec ;
  # --max-time : une application bloquée ne bloque pas le déploiement.
  if body="$(curl -fsS --max-time 5 "${CURL_OPTS[@]}" "$URL" 2>&1)" \
    && grep -Eq '"status" *: *"ok"' <<<"$body" \
    && { [ -z "$EXPECTED" ] || grep -Eq "\"version\" *: *\"$EXPECTED\"" <<<"$body"; }; then
    echo "Smoke test OK ($i/$RETRIES) : $body"
    exit 0
  fi
  echo "Essai $i/$RETRIES : pas encore bon -> ${body:0:200}"
  sleep "$DELAY"
done

echo "Smoke test ÉCHOUÉ sur $URL (version attendue : ${EXPECTED:-peu importe})" >&2
exit 1
