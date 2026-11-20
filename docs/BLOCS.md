# Catalogue des blocs devops-kit

Chaque bloc est une skill : `plugins/devops-kit/skills/<bloc>/SKILL.md` (signaux de détection, étapes, vérification,
gestes manuels), avec ses variantes par stack dans `references/` et ses modèles commentés dans `templates/`.
Les noms partagés entre blocs (services, variables, chemins, noms de jobs) sont dans
`plugins/devops-kit/skills/devops-apply/references/conventions.md`.

## Ordre et dépendances

```
git-collab ──▶ ci ──────────────────────────────▶ devsecops
                 ╲                                   ▲
docker-dev ──────▶ cd-release ──▶ iac               │ (proxy, staging pour ZAP)
     │                 │                             │
     └──▶ monitoring ◀─┘ (réseaux staging/prod) ─────┘
```

`devops-plan` applique les blocs choisis dans cet ordre : git-collab → ci → docker-dev → cd-release → iac /
monitoring / devsecops, un bloc par branche (`chore/devops-<bloc>`), empilées tant qu'elles ne sont pas fusionnées.

| Bloc | Obligatoire | Conseillé |
|---|---|---|
| `git-collab` | — | — |
| `ci` | — (sans `git-collab`, la CI ne bloque rien) | `git-collab` |
| `docker-dev` | — | `ci` (job `docker-build`) |
| `cd-release` | `docker-dev` | `ci`, `git-collab` |
| `iac` | `cd-release` | `git-collab` |
| `monitoring` | `docker-dev` | `cd-release` |
| `devsecops` | `ci` | `cd-release`, `git-collab` |

## Fichiers produits

### git-collab
| Fichier | Rôle |
|---|---|
| `.github/CODEOWNERS` | relecteurs obligatoires par chemin |
| `.github/pull_request_template.md` | ce qui change / pourquoi / comment vérifier |
| `.githooks/commit-msg` | refuse les messages hors Conventional Commits |
| `CONTRIBUTING.md` | comment contribuer |
| *(GitHub)* ruleset `protection-main`, réglages de fusion | PR obligatoire, squash, pas de force-push |

### ci
| Fichier | Rôle |
|---|---|
| `.github/workflows/ci.yml` | jobs `lint`, `test` (seuil de couverture), `integration` (vraie base), `build`, `docker-build` |
| ajouts au projet (scripts, config de couverture) | la CI ne lance que des commandes qui existent en local |
| *(GitHub)* checks requis dans le ruleset | une PR rouge ne se fusionne pas |

### docker-dev
| Fichier | Rôle |
|---|---|
| `Dockerfile` | multi-stage, non root, `APP_VERSION` en argument, `HEALTHCHECK` |
| `.dockerignore` | ni secrets ni dépendances du poste dans l'image |
| `compose.yaml` | application + PostgreSQL pour le développement, base non exposée |
| `.env.example`, `.gitignore` | modèle de configuration ; `.env` jamais versionné |
| route `/health` + test | `200 {"status":"ok","db":"up",…}`, `503` si la base ne répond pas |

### cd-release
| Fichier | Rôle |
|---|---|
| `.github/workflows/release.yml` | `prepare`, `build-push` (ghcr.io au SHA court), `scan` (Trivy), `deploy-staging`, `deploy-production` (approbation) |
| `.github/actionlint.yaml` | label du runner `deploy` (cible runner) |
| `.github/dependabot.yml` | mises à jour des dépendances, images et actions |
| `compose.prod.yaml` | staging et production : image publiée, proxy seul exposé |
| `deploy/deploy.sh`, `smoke-test.sh`, `backup.sh`, `gen-cert.sh`, `env.example` | déploiement, smoke test, rollback automatique, sauvegarde, certificat |
| `deploy/nginx/app.conf` | reverse proxy HTTPS, `/metrics` bloqué |
| `docs/DEPLOIEMENT.md` | exploitation et mise en place |
| *(hors dépôt)* runner `~/runners/<repo>/` ou utilisateur SSH ; environments GitHub | cible runner local ou VPS |

### iac
| Fichier | Rôle |
|---|---|
| `infra/*.tf`, `infra/.terraform.lock.hcl`, `terraform.tfvars.example` | le staging décrit en OpenTofu (provider docker) |
| `.github/workflows/iac.yml` | `fmt`, `validate`, `plan` publié en commentaire de PR |
| `release.yml` (job `deploy-staging` remplacé) | le staging est déployé par `tofu apply` ; la production reste en Compose |
| *(option)* `ansible/site.yml`, `inventory.ini.example`, `templates/env.j2` | préparation de la machine (Docker, utilisateur, dossiers, `.env`) |
| *(hors dépôt)* state OpenTofu | dans le `DEPLOY_DIR` du staging ou un bucket, jamais dans Git |

### monitoring
| Fichier | Rôle |
|---|---|
| code `/metrics` + test | `http_requests_total`, `http_request_duration_seconds` par route |
| `monitoring/compose.monitoring.yaml`, `.env.example` | Prometheus, Grafana, Alertmanager, blackbox, ports sur 127.0.0.1 |
| `monitoring/prometheus/prometheus.yml`, `rules/alertes.yml`, `tests/alertes.test.yml` | collecte ; alertes API indisponible, 5xx, latence ; tests promtool |
| `monitoring/alertmanager/alertmanager.yml`, `blackbox/blackbox.yml` | routage des alertes, sondes `/health` |
| `monitoring/grafana/provisioning/…`, `dashboards/application.json` | source de données et dashboard provisionnés |
| `docs/INCIDENTS.md` | journal des incidents et modèle de post-mortem |

### devsecops
| Fichier | Rôle |
|---|---|
| `.github/workflows/security.yml` | `secrets` (gitleaks, historique), `dependencies` (bloque high/critical), `sast` (Semgrep), `dast` (ZAP baseline sur le staging) |
| `.gitleaks.toml`, `.pre-commit-config.yaml`, `.githooks/pre-commit` | secrets bloqués avant le commit |
| `deploy/nginx/security-headers.conf`, `.zap/rules.tsv` | en-têtes de sécurité du proxy, règles ZAP |
| workflows existants modifiés | actions épinglées par SHA, permissions minimales |
| `docs/SECURITE.md` | outils, ce qui bloque, exceptions, fuite de secret |

## Stacks couvertes

Node / Next.js, Next.js + Convex (base hébergée : chaque bloc dit ce qui ne s'applique pas), Java (Maven, Gradle),
Rust (cargo), Elixir (mix, Phoenix).
