#!/usr/bin/env bash
# =============================================================================
# Test du template cd-release/templates/deploy/deploy.sh, SANS Docker :
# un faux `docker` (qui note ses appels) et un petit serveur /health en Python.
#
#     tests/cd-release-deploy.sh        # depuis la racine du dépôt devops-kit
#
# Vérifie : déploiement normal, mémorisation de la version précédente, rollback
# automatique quand le smoke test voit la mauvaise version, historique rétabli
# après rollback, refus d'un mauvais environnement et d'un tag invalide.
# =============================================================================
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
PORT=18080
trap 'kill "$SRV" 2>/dev/null || true; rm -rf "$T"' EXIT
export T

mkdir -p "$T/bin" "$T/env/deploy"
cp "$REPO"/plugins/devops-kit/skills/cd-release/templates/deploy/*.sh "$T/env/deploy/"
touch "$T/env/compose.prod.yaml"
printf 'COMPOSE_PROJECT_NAME=x-staging\nAPP_ENV=staging\nSMOKE_URL=http://127.0.0.1:%s/health\n' "$PORT" > "$T/env/.env"

# Faux docker : `up` fait « servir » IMAGE_TAG par /health, sauf le tag cassé bbbbbbb
# (l'ancienne version continue de répondre : le smoke test doit le voir).
cat > "$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"config --services"* ]]; then printf 'db\napp\nproxy\n'; fi
if [[ "$*" == *" up "* && "$IMAGE_TAG" != bbbbbbb ]]; then echo "$IMAGE_TAG" > "$T/served"; fi
exit 0
EOF
chmod +x "$T/bin/docker"
echo none > "$T/served"

python3 -I -c '
import http.server, sys
t = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        v = open(t + "/served").read().strip()
        self.send_response(200); self.end_headers()
        self.wfile.write(("{\"status\":\"ok\",\"db\":\"up\",\"version\":\"%s\"}" % v).encode())
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[2])), H).serve_forever()
' "$T" "$PORT" &
SRV=$!
sleep 1

export PATH="$T/bin:$PATH" SMOKE_RETRIES=2 SMOKE_DELAY=0
D="$T/env"
ok() { echo "OK  $1"; }
ko() { echo "KO  $1" >&2; exit 1; }

"$D/deploy/deploy.sh" staging aaaaaaa >/dev/null 2>&1 || ko "premier déploiement"
[ "$(cat "$D/.deployed-tag")" = aaaaaaa ] && ok "premier déploiement" || ko "premier déploiement : .deployed-tag"

"$D/deploy/deploy.sh" staging ccccccc >/dev/null 2>&1 || ko "deuxième déploiement"
[ "$(cat "$D/.previous-tag")" = aaaaaaa ] && ok "version précédente mémorisée" || ko ".previous-tag"

if "$D/deploy/deploy.sh" staging bbbbbbb >/dev/null 2>&1; then ko "un déploiement cassé doit sortir en erreur"; fi
[ "$(cat "$D/.deployed-tag")" = ccccccc ] && [ "$(cat "$T/served")" = ccccccc ] \
  && ok "rollback automatique vers ccccccc" || ko "rollback"
[ "$(cat "$D/.previous-tag")" = aaaaaaa ] && ok "historique rétabli après rollback" || ko ".previous-tag après rollback"

if "$D/deploy/deploy.sh" production ccccccc >/dev/null 2>&1; then ko "mauvais environnement accepté"; fi
ok "mauvais environnement refusé"
if "$D/deploy/deploy.sh" staging 'x;rm -rf' >/dev/null 2>&1; then ko "tag invalide accepté"; fi
ok "tag invalide refusé"
