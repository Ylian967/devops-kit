---
name: monitoring
description: Bloc devops-kit « supervision » — instrumente l'application avec un endpoint GET /metrics au format Prometheus (http_requests_total et http_request_duration_seconds par method/route/status ; Node/Next.js avec prom-client, Next.js + Convex, Java Micrometer/Actuator, Rust axum, Elixir Phoenix), puis écrit monitoring/ : compose.monitoring.yaml (Prometheus, Grafana, Alertmanager, blackbox exporter, ports sur 127.0.0.1) qui rejoint le réseau Docker de staging et production, prometheus.yml, règles d'alerte (application indisponible, taux de 5xx, latence p95, certificat) avec tests unitaires promtool, alertmanager.yml (webhook, Discord ou mail, inhibition), sondes blackbox sur /health interne et URL publique, datasource et dashboard Grafana provisionnés, et docs/INCIDENTS.md avec un modèle de post-mortem sans blâme. À utiliser quand l'utilisateur veut des métriques, Prometheus, Grafana, des dashboards, être alerté quand son application tombe ou ralentit, surveiller une URL, ou documenter ses incidents.
---

# Bloc monitoring

Objectif : savoir **avant les utilisateurs** que l'application est tombée, renvoie des erreurs ou ralentit ; voir
depuis quand et où dans un dashboard ; et transformer chaque incident en amélioration écrite.

Procédure générale (branche, « rien n'est écrasé », commit, PR) : `${CLAUDE_PLUGIN_ROOT}/skills/devops-apply/SKILL.md`.
Noms partagés (`/metrics`, `/health`, réseau `<repo>-<env>_default`, dossier `monitoring/`, services) :
`${CLAUDE_PLUGIN_ROOT}/skills/devops-apply/references/conventions.md`.

## Règles propres à ce bloc

- **Rien n'est écrasé sans diff et accord** (règle commune), y compris un `docs/INCIDENTS.md` ou un dashboard existant.
- **Prometheus, Alertmanager et Grafana ne sont jamais exposés publiquement sans protection.** Prometheus et
  Alertmanager n'ont aucune authentification. Ports publiés sur `127.0.0.1` uniquement, accès distant par **tunnel
  SSH** (documenté dans `docs/INCIDENTS.md`). Ne pas ajouter de `location` vers eux dans le proxy public ; si
  l'utilisateur veut Grafana sur Internet, c'est un sujet à part (HTTPS + authentification forte), le dire et ne pas
  le faire dans ce bloc.
- **`/metrics` ne sort jamais par le proxy public** (`deploy/nginx/app.conf` du bloc cd-release renvoie déjà 404).
- **Aucun secret versionné** : mot de passe Grafana dans `monitoring/.env`, URL de webhook et mot de passe SMTP dans
  `monitoring/secrets/`, tous deux dans le `.gitignore`.

## Dépendances

- **docker-dev** (obligatoire) : `/health` au format commun (les sondes cherchent `"status":"ok"`), application en
  conteneur.
- **cd-release** (conseillé) : on supervise staging et production. Le bloc rejoint leurs réseaux
  `<repo>-staging_default` et `<repo>-production_default`, et compte sur le proxy pour bloquer `/metrics`. Sans
  cd-release : superviser l'environnement de `compose.yaml` (réseau `<repo>_default`, `env: local`) pour apprendre,
  en le disant ; ou seulement des sondes publiques si l'application est hébergée ailleurs.
- **ci** (facultatif) : le test du middleware `/metrics` tourne avec les tests unitaires ; proposer en plus un job
  `monitoring` qui lance `promtool` et `amtool` (commandes de *Vérification*), non requis par le ruleset.

## Signaux de détection

| Élément | Déjà en place si… | Commande |
|---|---|---|
| Instrumentation | bibliothèque Prometheus dans les dépendances | `grep -nE 'prom-client\|micrometer-registry-prometheus\|metrics-exporter-prometheus\|"prometheus"\|telemetry_metrics_prometheus\|prom_ex' package.json pom.xml build.gradle* Cargo.toml mix.exs 2>/dev/null` |
| Route `/metrics` | une route qui sert le registre | `grep -rnE "['\"]/metrics['\"]\|path-mapping.prometheus\|/actuator/prometheus" src lib app config 2>/dev/null` |
| Noms au contrat | `http_requests_total` et `http_request_duration_seconds` avec `method`, `route`, `status` | lire le code ; `status_code`, `path` ou URL brute dans `route` = partiel, à corriger |
| Stack de supervision | `monitoring/`, `prometheus.yml`, images `prom/*` ou `grafana/*` | `ls monitoring 2>/dev/null; grep -rlnE 'prom/prometheus\|grafana/grafana' --include='*.y*ml' . 2>/dev/null` |
| Règles d'alerte et tests | `alert:` dans des règles ; `tests:` pour promtool | `grep -rln 'alert:' monitoring 2>/dev/null; grep -rln 'alert_rule_test' monitoring 2>/dev/null` |
| Destinataire des alertes | `receivers:` avec un canal réel | `grep -nA3 'receivers:' monitoring/alertmanager/*.yml 2>/dev/null` |
| `/metrics` bloqué au proxy | `location ^~ /metrics` (et `/actuator` en Java) | `grep -n 'metrics\|actuator' deploy/nginx/*.conf 2>/dev/null` |
| Ports exposés | un port publié sans `127.0.0.1:` devant | `grep -nE -e '- "?(\$\{[^}]+\}\|[0-9]+):[0-9]+' monitoring/*.y*ml 2>/dev/null` : toute ligne = **problème** à signaler |
| Post-mortems | `docs/INCIDENTS.md` (ou `docs/postmortems/`) | `ls docs 2>/dev/null` |

- **Autre outil déjà en place** (Datadog, New Relic, Grafana Cloud, Sentry, UptimeRobot, Better Stack…) : le dire,
  demander s'il faut le garder (proposer alors seulement ce qui manque : `/metrics` au contrat, `INCIDENTS.md`) ou
  le remplacer.
- **Application hébergée sur une plateforme** (Vercel, Render, Fly.io…) : pas de réseau à rejoindre, rien à collecter
  en interne ; seulement des sondes publiques, et le dire (`references/nextjs-convex.md`, fin).

## Étapes

1. **Stack et référence** :

   | Stack | Instrumentation | Référence |
   |---|---|---|
   | Node (node:http, Express, Fastify), Next.js | `templates/metrics/node-http.js` + `node-http.test.js` | `references/node.md` |
   | Next.js + Convex | idem, partiel | `references/nextjs-convex.md` (+ `node.md`) |
   | Java (Spring Boot) | Micrometer + Actuator, renommage dans `prometheus.yml` | `references/java.md` |
   | Rust (axum) | `metrics` + `metrics-exporter-prometheus` | `references/rust.md` |
   | Elixir (Phoenix) | `telemetry_metrics_prometheus_core` | `references/elixir.md` |

   Monorepo : chaque composant qui sert du HTTP a son `/metrics` ; un job par composant dans `prometheus.yml`
   (`api`, `front`), et le `job="app"` des règles et du dashboard remplacé par `job=~"api|front"`.
2. **Questions** (AskUserQuestion), une ligne d'explication chacune :
   - *où tourne la supervision* : sur la machine de staging et production (un seul serveur, ou runner local) ; deux
     serveurs : sur celui de production, et le staging seulement par sa sonde publique ;
   - *qui prévenir* : webhook générique, salon Discord, ou mail (SMTP) ;
   - *les URL publiques* de chaque environnement (lues dans `docs/DEPLOIEMENT.md` / `deploy/env.example` si cd-release
     est en place).
3. **Instrumenter `/metrics`** d'après la référence : dépendance, code, route servie **avant** la mesure, test qui
   prouve `route` = motif (pas l'URL), `unmatched`, 5xx comptées, `/metrics` non comptée. Lancer les tests du projet.
   Vérifier que le proxy bloque `/metrics` (et `/actuator` en Java) ; sinon l'ajouter (diff + accord).
4. **`monitoring/`** depuis `templates/monitoring/` (même arborescence) :
   - partout : `monapp` → nom du dépôt ; port interne de la stack (Node/Next.js 3000, Java/Rust 8080, Phoenix 4000) ;
   - `compose.monitoring.yaml` : un réseau externe par environnement présent sur la machine (supprimer les autres) ;
   - `prometheus/prometheus.yml` : cibles par **nom de conteneur** (`<repo>-<env>-app-1`) ; sondes interne et publique
     par environnement ; renommage Java/Elixir si la référence le demande. Cible runner local (certificat auto-signé,
     pas de vraie URL publique) : la sonde « publique » vise le proxy, `https://<repo>-<env>-proxy-1/health`, dans un
     second job `blackbox-proxy` avec le module `http_health_autosigne` ;
   - `prometheus/rules/alertes.yml` et `prometheus/tests/alertes.test.yml` : seuils gardés par défaut (5 % de 5xx,
     p95 500 ms) sauf mesure contraire ; tout texte d'annotation modifié se reporte dans les tests ;
   - `alertmanager/alertmanager.yml` : le receiver choisi actif, les deux autres en commentaire ;
   - `grafana/` : copié tel quel (datasource `uid: prometheus`, dashboard `application.json`) ;
   - `monitoring/.env.example` depuis `templates/env.monitoring.example`.
5. **`.gitignore`** : `monitoring/.env`, `monitoring/secrets/`.
6. **`docs/INCIDENTS.md`** depuis `templates/INCIDENTS.md` : destinataire des notifications, commandes adaptées
   (`compose.prod.yaml`, nom du service), sections des alertes ajoutées par la référence (`ConvexIndisponible`).
   Existant : proposer la fusion (garder son journal et ses post-mortems, ajouter ce qui manque).
7. **Formater et vérifier** (section suivante). Le formateur du projet (Prettier) peut reformater
   `application.json` : relancer `python3 -m json.tool` après.
8. **Commit** : `feat(monitoring): ajoute les métriques, la supervision et les alertes` (ou deux commits : l'endpoint
   `/metrics`, puis `monitoring/` + `docs/INCIDENTS.md`).
9. La stack n'est **pas démarrée** par Claude sur un serveur sans accord explicite (machine hors du dépôt). Proposer les
   commandes des *Gestes manuels* ; ne les lancer que si l'utilisateur le demande et que c'est le poste local.

## Fichiers produits

| Fichier | Source |
|---|---|
| Code `/metrics` + test (selon la stack) | `templates/metrics/` ou `references/<stack>.md` |
| `monitoring/compose.monitoring.yaml` | `templates/monitoring/compose.monitoring.yaml` |
| `monitoring/prometheus/prometheus.yml` | `templates/monitoring/prometheus/prometheus.yml` |
| `monitoring/prometheus/rules/alertes.yml` | `templates/monitoring/prometheus/rules/alertes.yml` |
| `monitoring/prometheus/tests/alertes.test.yml` | `templates/monitoring/prometheus/tests/alertes.test.yml` |
| `monitoring/alertmanager/alertmanager.yml` | `templates/monitoring/alertmanager/alertmanager.yml` |
| `monitoring/blackbox/blackbox.yml` | `templates/monitoring/blackbox/blackbox.yml` |
| `monitoring/grafana/provisioning/datasources/prometheus.yml`, `…/dashboards/dashboards.yml` | `templates/monitoring/grafana/provisioning/` |
| `monitoring/grafana/dashboards/application.json` | `templates/monitoring/grafana/dashboards/application.json` |
| `monitoring/.env.example` | `templates/env.monitoring.example` |
| `docs/INCIDENTS.md` | `templates/INCIDENTS.md` |
| `.gitignore` (ajouts) | étape 5 |

## Vérification

Depuis la racine du dépôt, outils en conteneur (rien à installer) :

```bash
M="$PWD/monitoring"
# Prometheus : configuration (rules/*.yml compris, chemin relatif), règles, tests unitaires des alertes
docker run --rm -v "$M/prometheus":/p -w /p --entrypoint promtool prom/prometheus:v3.16.0 check config prometheus.yml
docker run --rm -v "$M/prometheus":/p -w /p --entrypoint promtool prom/prometheus:v3.16.0 check rules rules/alertes.yml
docker run --rm -v "$M/prometheus":/p -w /p --entrypoint promtool prom/prometheus:v3.16.0 test rules tests/alertes.test.yml
# Alertmanager
docker run --rm -v "$M/alertmanager":/a --entrypoint amtool prom/alertmanager:v0.35.0 check-config /a/alertmanager.yml
# Blackbox
docker run --rm -v "$M/blackbox":/b prom/blackbox-exporter:v0.29.1 --config.file=/b/blackbox.yml --config.check
# Compose (valeurs factices ; les réseaux externes n'ont pas besoin d'exister pour `config`)
docker compose --env-file monitoring/.env.example -f monitoring/compose.monitoring.yaml config -q
# Dashboards : JSON valide
for f in monitoring/grafana/dashboards/*.json; do python3 -m json.tool "$f" >/dev/null && echo "OK $f"; done
# Ports : aucune ligne ne doit sortir (tout port publié commence par 127.0.0.1)
docker compose --env-file monitoring/.env.example -f monitoring/compose.monitoring.yaml config --format json \
  | jq -r '.services[].ports[]? | select(.host_ip != "127.0.0.1") | .published'
# /metrics : les tests du projet (node --test, mvn test, cargo test, mix test) passent
```

Preuve que les tests d'alerte servent (à proposer) : passer `for: 2m` à `for: 30s` dans `AppIndisponible`, relancer
`promtool test rules` → échec ; remettre.

**Après démarrage** (environnements déployés, puis `docker compose -f compose.monitoring.yaml up -d` dans
`monitoring/` avec son `.env`) :

- http://localhost:9090/targets : toutes les cibles `UP` (`prometheus`, `app` par environnement, `blackbox-health`
  par sonde, `blackbox`) ; `no such host` = réseau non rejoint ou environnement arrêté ;
- requête `probe_success` : 1 partout ; `sum by (route) (rate(http_requests_total[5m]))` après quelques requêtes ;
- http://localhost:3001 : dashboard *Application : disponibilité et RED* en page d'accueil, courbes qui bougent ;
- http://localhost:9093 : `Watchdog` active ; envoyer une alerte d'essai (commande `amtool alert add` en tête de
  `alertmanager.yml`) et vérifier sa réception sur le canal choisi ;
- répétition d'incident (à proposer, sur le staging, dans son `DEPLOY_DIR`) :
  `export IMAGE_TAG=$(cat .deployed-tag) && docker compose -f compose.prod.yaml stop app` → `AppIndisponible`
  notifiée après ~2 min, `CibleIllisible` inhibée ; `docker compose -f compose.prod.yaml start app` → notification
  *résolue*.

## Gestes manuels à laisser à l'utilisateur

- [ ] Copier `monitoring/` sur la machine de supervision (ou l'utiliser depuis un clone du dépôt) et créer
      `monitoring/.env` depuis `.env.example` avec un **vrai mot de passe Grafana** (`chmod 600`). Il n'est lu qu'au
      premier démarrage ; ensuite : `docker compose -f compose.monitoring.yaml exec grafana grafana cli admin reset-admin-password <nouveau>`.
- [ ] Choisir et brancher le **destinataire des alertes** : créer le webhook (Discord : *Paramètres du salon →
      Intégrations → Webhooks*) ou le compte SMTP, écrire l'URL ou le mot de passe dans
      `monitoring/secrets/webhook-url` (ou `discord-webhook-url`, `smtp-password`), `chmod 600`, jamais dans Git ;
      puis envoyer l'alerte d'essai.
- [ ] Démarrer la stack **après** les environnements (`docker compose -f compose.monitoring.yaml up -d`) ; la
      redémarrer si un environnement est créé ensuite (son réseau doit exister).
- [ ] Accès distant uniquement par **tunnel SSH** (`ssh -N -L 3001:127.0.0.1:3001 -L 9090:127.0.0.1:9090 -L 9093:127.0.0.1:9093 <utilisateur>@<serveur>`) ;
      vérifier qu'aucun pare-feu n'ouvre 9090, 9093, 3001.
- [ ] Ajuster les seuils (`LatenceElevee` surtout) après une ou deux semaines de mesures réelles, tests promtool compris.
- [ ] Optionnel : un service de battement de cœur externe pour le `Watchdog` (prévient si la supervision elle-même
      tombe : une machine ne peut pas signaler sa propre panne).
- [ ] Au premier incident : remplir le journal et un post-mortem dans `docs/INCIDENTS.md`, ouvrir les issues des actions.
