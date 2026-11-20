#!/usr/bin/env bash
# =============================================================================
# gen-cert.sh : certificat HTTPS AUTO-SIGNÉ, pour un serveur sans nom de domaine
# public (runner local, poste de développement) ou pour le premier démarrage d'un
# VPS, avant que Let's Encrypt (certbot) ne le remplace.
#
#     deploy/gen-cert.sh                       # dans $DEPLOY_DIR
#     DOMAIN=monapp.localhost deploy/gen-cert.sh
#     FORCE=1 deploy/gen-cert.sh               # régénérer
#
# Résultat : certs/fullchain.pem (public) et certs/privkey.pem (PRIVÉE, 600).
# Mêmes noms que Let's Encrypt : deploy/nginx/app.conf ne change pas entre les deux.
#
# Le chiffrement est réel ; seule l'identité n'est garantie par personne, d'où
# l'avertissement du navigateur. Le SAN contient localhost et host.docker.internal :
# le smoke test peut VÉRIFIER ce certificat (curl --cacert certs/fullchain.pem)
# au lieu de tout accepter (curl -k).
# Dépendance : openssl (présent sur presque tous les serveurs).
# =============================================================================
set -euo pipefail

DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
CERT_DIR="$DEPLOY_DIR/certs"
DOMAIN="${DOMAIN:-app.localhost}"
DAYS="${DAYS:-365}"

mkdir -p "$CERT_DIR"
if [ -f "$CERT_DIR/fullchain.pem" ] && [ -f "$CERT_DIR/privkey.pem" ] && [ "${FORCE:-0}" != 1 ]; then
  echo "Certificat déjà présent dans $CERT_DIR (FORCE=1 pour le régénérer)."
  exit 0
fi

command -v openssl >/dev/null || { echo "openssl requis (apt install openssl)" >&2; exit 1; }
# -x509 -nodes : certificat auto-signé, clé non chiffrée (Nginx doit la lire seul au démarrage)
openssl req -x509 -nodes -newkey rsa:2048 -days "$DAYS" -subj "/CN=$DOMAIN" \
  -addext "subjectAltName=DNS:$DOMAIN,DNS:localhost,DNS:host.docker.internal,IP:127.0.0.1" \
  -keyout "$CERT_DIR/privkey.pem" -out "$CERT_DIR/fullchain.pem" 2>/dev/null

# Clé privée lisible par son seul propriétaire : le processus maître de Nginx la
# lit en root dans le conteneur, cela suffit.
chmod 600 "$CERT_DIR/privkey.pem"
chmod 644 "$CERT_DIR/fullchain.pem"
echo "Certificat auto-signé créé dans $CERT_DIR (pour $DOMAIN, $DAYS jours)"
