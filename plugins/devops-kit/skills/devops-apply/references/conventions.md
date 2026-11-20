# Conventions communes à tous les blocs devops-kit

Les blocs s'emboîtent parce qu'ils partagent ces noms. Un bloc qui s'en écarte doit le dire. Si le projet a déjà ses
propres noms (service `web` au lieu de `app`, autre port…), **on garde ceux du projet** et on les reporte partout
de façon cohérente.

## Application

| Élément | Convention |
|---|---|
| Variables d'environnement | `PORT`, `DATABASE_URL`, `APP_ENV` (`local`, `staging`, `production`), `APP_VERSION` (SHA court en prod, `dev` sinon) |
| Port interne | celui de la stack : Node 3000, Next.js 3000, Java/Spring 8080, Rust 8080, Phoenix 4000 (lu depuis `PORT`) |
| `GET /health` | `200 {"status":"ok","db":"up","version":"…","env":"…"}` ; base injoignable : `503 {"status":"degraded","db":"down",…}` ; projet sans base (ou base hébergée comme Convex) : `"db":"none"`, 200 |
| `GET /metrics` | format Prometheus ; au minimum `http_requests_total{method,route,status}` et l'histogramme `http_request_duration_seconds{method,route,status}` ; `route` = le motif (`/tasks/:id`), jamais l'URL brute ; **jamais exposé par le proxy public** |
| Logs | une ligne JSON par requête sur la sortie standard |

## Conteneurs (Compose)

| Élément | Convention |
|---|---|
| Fichiers | `compose.yaml` (dev), `compose.prod.yaml` (staging et production), `monitoring/compose.monitoring.yaml` |
| Services | `app` (ou un par composant d'un monorepo : `api`, `front`…), `db`, `proxy` (prod) ; monitoring : `prometheus`, `grafana`, `alertmanager`, `blackbox` |
| Base | `postgres:17-alpine`, volume nommé `pgdata`, jamais de port publié hors dev |
| Nom de projet Compose | `<repo>-<env>` (`-p` ou `name:`), ex. `monapp-staging`, `monapp-production` ; réseau par défaut `<repo>-<env>_default` |
| Secrets | `.env` (jamais versionné) à côté du fichier compose ; `.env.example` versionné, valeurs factices |

## Images et livraison

| Élément | Convention |
|---|---|
| Registre | `ghcr.io/<owner>/<repo>` (minuscules), suffixe `-<composant>` en monorepo |
| Tag | SHA court du commit (7 caractères, `git rev-parse --short=7 HEAD`) ; jamais `latest` en déploiement |
| Variable de déploiement | `IMAGE_TAG` lue par `compose.prod.yaml` |
| Environnements GitHub | `staging` (automatique), `production` (*required reviewers*) |
| Workflows | `ci.yml` (jobs `lint`, `test`, `integration`, `build`, `docker-build`), `release.yml` (`build-push`, `scan`, `deploy-staging`, `deploy-production`), `iac.yml` (`fmt`, `validate`, `plan`), `security.yml` (`secrets`, `dependencies`, `sast`, `dast`) |
| Runner self-hosted | labels `[self-hosted, deploy]`, déclarés dans `.github/actionlint.yaml` |
| Dossier de déploiement | variable `DEPLOY_DIR` : `~/deploy/<repo>-<env>` (runner local) ou `/opt/<repo>/<env>` (VPS) ; contient `compose.prod.yaml`, `.env`, `deploy/`, `backups/` |
| Scripts | `deploy/deploy.sh <env> <tag>`, `deploy/smoke-test.sh <url>`, `deploy/backup.sh <env>` ; tags mémorisés dans `$DEPLOY_DIR/.deployed-tag` et `.previous-tag` |
| Proxy | `deploy/nginx/app.conf`, en-têtes de sécurité dans `deploy/nginx/security-headers.conf` (bloc devsecops), certificats dans `$DEPLOY_DIR/certs/` (jamais versionnés) |

## Infrastructure et supervision

| Élément | Convention |
|---|---|
| OpenTofu | `infra/` : `versions.tf`, `providers.tf`, `variables.tf`, `main.tf`, `outputs.tf`, `terraform.tfvars.example` ; le state n'est jamais versionné |
| Ansible | `ansible/` : `inventory.ini.example`, `site.yml`, `templates/` |
| Monitoring | `monitoring/` : `prometheus/prometheus.yml`, `prometheus/rules/alertes.yml`, `prometheus/tests/`, `alertmanager/alertmanager.yml`, `blackbox/blackbox.yml`, `grafana/provisioning/…`, `grafana/dashboards/*.json` |
| Sécurité | `.gitleaks.toml`, `.githooks/pre-commit` (gitleaks, à côté de `commit-msg`), `.zap/rules.tsv` ; variable de dépôt `STAGING_URL` (cible de ZAP) |
| Documentation | `docs/DEPLOIEMENT.md`, `docs/INCIDENTS.md`, `docs/SECURITE.md` |

## Vérifier sans rien installer

Les outils absents du poste se lancent en conteneur, depuis la racine du dépôt :

```bash
docker run --rm -v "$PWD":/repo -w /repo rhysd/actionlint:1.7.12 -color                   # workflows
docker run --rm -i hadolint/hadolint:v2.15.1 < Dockerfile                                  # Dockerfile
docker compose -f compose.yaml config -q                                                   # compose
docker run --rm -v "$PWD/deploy/nginx":/etc/nginx/conf.d:ro nginx:1.29-alpine nginx -t     # nginx (certificats requis : voir cd-release)
docker run --rm -v "$PWD/monitoring/prometheus":/p -w /p --entrypoint promtool prom/prometheus:v3.16.0 check config prometheus.yml
docker run --rm -v "$PWD":/repo zricethezav/gitleaks:v8.30.1 git /repo                     # secrets dans l'historique
```
