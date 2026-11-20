---
name: cd-release
description: Bloc devops-kit « livraison continue » — écrit .github/workflows/release.yml qui, à chaque merge sur main, construit l'image, la pousse sur ghcr.io taguée au SHA court, la scanne avec Trivy, déploie le staging automatiquement puis la production après approbation (GitHub Environments), lance un smoke test sur /health et revient tout seul à la version précédente en cas d'échec ; ajoute compose.prod.yaml, deploy/ (deploy.sh, smoke-test.sh, backup.sh, gen-cert.sh, reverse proxy Nginx en HTTPS), dependabot.yml et docs/DEPLOIEMENT.md. Deux cibles : runner self-hosted local ou VPS en SSH. À utiliser quand l'utilisateur veut déployer automatiquement, publier ses images Docker, avoir un staging et une production, un rollback, du HTTPS devant son application ou Dependabot.
---

# Bloc cd-release

Objectif : un merge sur `main` arrive en staging sans geste humain, puis en production après un clic d'approbation ;
la même image (scannée) sert les deux ; un déploiement raté revient seul à la version précédente ; aucun secret
n'est dans Git.

Procédure générale (branche, « rien n'est écrasé », commit, PR) : `${CLAUDE_PLUGIN_ROOT}/skills/devops-apply/SKILL.md`.
Noms partagés (`DEPLOY_DIR`, `IMAGE_TAG`, `.deployed-tag`, labels du runner, noms de jobs) :
`${CLAUDE_PLUGIN_ROOT}/skills/devops-apply/references/conventions.md`.

## Dépendances

- **docker-dev** (obligatoire) : `Dockerfile` qui construit l'image de production, route `/health` au format commun
  (le smoke test vérifie `"status":"ok"` **et** la version), healthcheck.
- **ci** (fortement conseillé) : sans CI requise sur les PR, `main` peut recevoir du code cassé qui partira en staging.
- **git-collab** (conseillé) : `main` protégée, sinon un push direct déclenche une livraison.
- Prolongé par **iac** (le staging décrit en OpenTofu), **monitoring** (rejoint le réseau `<projet>_default`),
  **devsecops** (`security-headers.conf` inclus par le proxy).

## Signaux de détection

| Élément | Déjà en place si… | Commande |
|---|---|---|
| Workflow de livraison | un workflow sur `push` de `main` ou sur tag qui fait `docker push` / un déploiement | `grep -ln 'docker push\|build-push-action\|deploy' .github/workflows/*.y*ml` |
| Registre | images sur ghcr.io (ou autre) | `gh api "users/{owner}/packages?package_type=container" --jq '.[].name'` (ou `orgs/…`) |
| Scan d'image | `trivy`, `grype`, `docker scout` dans un workflow | `grep -rn 'trivy\|grype\|scout' .github/workflows` |
| Environments | `staging`, `production`, et reviewers sur production | `gh api "repos/{owner}/{repo}/environments" --jq '.environments[] \| {name, rules: [.protection_rules[].type]}'` |
| Compose de prod | `compose.prod.yaml` (ou `docker-compose.prod.yml`) sans `build:` | `ls compose*.y*ml` |
| Scripts | `deploy/`, `scripts/deploy*` | `ls deploy scripts 2>/dev/null` |
| Proxy HTTPS | config Nginx / Caddy / Traefik | `ls deploy/nginx 2>/dev/null; grep -ln 'caddy\|traefik\|nginx' compose*.y*ml` |
| Dependabot | `.github/dependabot.yml` (ou `renovate.json`) | `ls .github/dependabot.yml renovate.json 2>/dev/null` |
| Doc | `docs/DEPLOIEMENT.md` ou section déploiement du README | `ls docs` |
| Runner self-hosted | runners enregistrés | `gh api "repos/{owner}/{repo}/actions/runners" --jq '.runners[] \| {name, status, labels: [.labels[].name]}'` |

- **Ne s'applique pas** tel quel : hébergement PaaS qui déploie déjà depuis Git (Vercel, Netlify, Render, Fly.io,
  Railway) — le dire ; proposer seulement Dependabot, et éventuellement le scan d'image si une image est construite.
- **Next.js + Convex** : voir `references/stacks.md` (pas de base dans le compose, `npx convex deploy`).
- Pas de `Dockerfile` : proposer `docker-dev` d'abord.

## Étapes

1. **Choisir la cible** (AskUserQuestion), en expliquant en une ligne chacune (détail : `references/cibles.md`) :
   - *runner self-hosted local* : staging et production tournent sur une machine à soi (poste, serveur maison), un
     runner en conteneur y pilote Docker ; aucun port à ouvrir sur Internet ;
   - *VPS en SSH* : un serveur loué ; GitHub s'y connecte en SSH avec une clé dédiée ; Let's Encrypt possible.
   Demander aussi : un seul serveur pour staging et production, ou deux ? domaine public (VPS) ?
2. **Inventaire** : port interne, variables lues par l'application (toutes devront être dans `compose.prod.yaml`
   et `deploy/env.example`), commande de migration, composants (monorepo → une image par composant,
   `references/stacks.md`), propriétaire GitHub en minuscules.
3. **`compose.prod.yaml`** depuis `templates/compose.prod.yaml` : variables de l'application (`${VAR:?…}`), port,
   healthcheck de la stack (`references/stacks.md`), `proxy_pass` cohérent. Pas de base → retirer `db`, `pgdata`,
   `DATABASE_URL`, et `depends_on: db`.
4. **`deploy/`** : `deploy.sh`, `smoke-test.sh`, `backup.sh` (si base PostgreSQL ; autre moteur : adapter la commande
   de dump), `gen-cert.sh`, `nginx/app.conf` (`server_name`, port), et `deploy/env.example` depuis
   `templates/env.deploy.example` (valeurs factices ; `COMPOSE_PROJECT_NAME`, `IMAGE_NAME`, `SMOKE_URL` adaptés à
   la cible). Garder le bit exécutable des scripts (`git add --chmod=+x`).
5. **`.github/workflows/release.yml`** depuis `templates/release-runner.yml` ou `templates/release-vps.yml` :
   - le contexte et le Dockerfile (monorepo : matrice, `references/stacks.md`) ;
   - garder `permissions: {}` et les permissions par job, les actions épinglées par SHA (vérifier qu'elles sont à
     jour : `gh api repos/<action>/releases/latest --jq .tag_name` puis
     `git ls-remote https://github.com/<action> 'refs/tags/<tag>^{}' 'refs/tags/<tag>'` — prendre la ligne `^{}`
     si elle existe), les entrées passées par `env:`, `concurrency` par environnement sans annulation ;
   - garder les noms de jobs `prepare`, `build-push`, `scan`, `deploy-staging`, `deploy-production`.
   Cible runner : ajouter `templates/actionlint.yaml` en `.github/actionlint.yaml` (ou fusionner le label `deploy`).
6. **`.github/dependabot.yml`** depuis `templates/dependabot.yml` : écosystèmes et dossiers du projet.
7. **`docs/DEPLOIEMENT.md`** depuis `templates/DEPLOIEMENT.md` : URL, dossiers, cible choisie (supprimer l'autre).
8. **`.gitignore`** : `certs/`, `backups/`, `letsencrypt/`, `*.pem`, `*.key`.
9. **Commit** : `build: ajoute la livraison continue (release, staging, production)`.
10. **Côté GitHub** (accord explicite, commandes montrées avant, après le push de la branche) :
    ```bash
    gh api -X PUT "repos/{owner}/{repo}/environments/staging" --silent
    uid=$(gh api user --jq .id)
    gh api -X PUT "repos/{owner}/{repo}/environments/production" --input - <<EOF
    {"reviewers":[{"type":"User","id":$uid}],
     "deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}
    EOF
    gh api -X POST "repos/{owner}/{repo}/environments/production/deployment-branch-policies" -f name=main -f type=branch
    gh variable set DEPLOY_DIR --env staging --body "<chemin>"      # idem production, APP_URL, SSH_* (cible VPS)
    ```
    Les reviewers d'environment exigent un dépôt **public** (ou un compte payant). Solo : l'auteur peut approuver son
    propre déploiement (laisser *Prevent self-review* décoché). Le secret `SSH_PRIVATE_KEY` n'est **jamais** saisi
    par Claude : `gh secret set SSH_PRIVATE_KEY --env production < deploy_key` est un geste manuel.
11. Le **serveur** (dossiers, `.env`, certificats, runner ou utilisateur SSH) n'est pas préparé par Claude sans
    accord explicite : c'est une machine hors du dépôt. Proposer les commandes de `docs/DEPLOIEMENT.md`, les lancer
    seulement si l'utilisateur le demande et que la machine est le poste local.

## Fichiers produits

| Fichier | Source |
|---|---|
| `.github/workflows/release.yml` | `templates/release-runner.yml` ou `templates/release-vps.yml` |
| `.github/actionlint.yaml` (cible runner) | `templates/actionlint.yaml` |
| `.github/dependabot.yml` | `templates/dependabot.yml` |
| `compose.prod.yaml` | `templates/compose.prod.yaml` |
| `deploy/deploy.sh`, `smoke-test.sh`, `backup.sh`, `gen-cert.sh` | `templates/deploy/` |
| `deploy/nginx/app.conf` | `templates/deploy/nginx/app.conf` |
| `deploy/env.example` | `templates/env.deploy.example` |
| `docs/DEPLOIEMENT.md` | `templates/DEPLOIEMENT.md` |
| (hors dépôt) runner : `~/runners/<repo>/compose.yaml`, `.env` | `templates/runner/` |
| (hors dépôt) environments, variables | étape 10 |

## Vérification

```bash
docker run --rm -v "$PWD":/repo -w /repo rhysd/actionlint:1.7.12 -color        # release.yml (+ shellcheck)
for f in deploy/*.sh; do bash -n "$f"; done                                       # syntaxe des scripts
docker run --rm -v "$PWD":/mnt -w /mnt koalaman/shellcheck:v0.11.0 deploy/*.sh   # bonnes pratiques shell
git ls-files -s deploy/*.sh                                                       # mode 100755
# compose.prod.yaml avec des valeurs factices (aucun .env réel nécessaire)
cp deploy/env.example /tmp/devops-kit.env
IMAGE_TAG=abcdef0 docker compose --env-file /tmp/devops-kit.env -f compose.prod.yaml config -q
# Nginx : la config se charge (certificat de test généré à la volée)
tmp=$(mktemp -d) && DEPLOY_DIR=$tmp deploy/gen-cert.sh && \
  docker run --rm --add-host app:127.0.0.1 -v "$PWD/deploy/nginx/app.conf":/etc/nginx/conf.d/default.conf:ro \
    -v "$PWD/deploy/nginx":/etc/nginx/snippets:ro -v "$tmp/certs":/etc/nginx/certs:ro nginx:1.29-alpine nginx -t
```

**Répétition générale en local** (à proposer, Docker requis) : construire l'image, créer un `DEPLOY_DIR` jetable
avec un `.env` de test (`PULL_POLICY=missing`, `IMAGE_NAME` = nom local), puis
`deploy/deploy.sh staging <tag>` : attendu `Smoke test OK` ; relancer avec un tag dont l'image répond 503 (ou
inexistante) : attendu le rollback automatique vers le tag précédent et un code de sortie 1.

Après le premier merge : *Actions → Release* — `scan` vert, `deploy-staging` vert, `deploy-production` en
*Waiting for review* ; puis `curl` sur les deux `/health` : même `version`, `env` différent.

## Gestes manuels à laisser à l'utilisateur

- [ ] Créer les dossiers d'environnement et leur `.env` (mots de passe **différents** par environnement, `chmod 600`).
- [ ] Certificats : `deploy/gen-cert.sh` (local) ou Let's Encrypt (VPS, `docs/DEPLOIEMENT.md`).
- [ ] Cible runner : jeton d'enregistrement (1 h), `docker compose up -d` du runner, vérifier *Idle* ; dépôt
      public : exiger l'approbation des workflows des contributeurs externes.
- [ ] Cible VPS : utilisateur `deploy` dans le groupe docker, clé SSH dédiée, secret `SSH_PRIVATE_KEY` par
      environment, variable `SSH_KNOWN_HOSTS` (empreinte vérifiée).
- [ ] Environments si l'étape 10 n'a pas été faite : `staging`, `production` avec *Required reviewers* et branche
      `main` seulement ; variables `DEPLOY_DIR`, `APP_URL`.
- [ ] Après le premier `build-push` : relier le paquet ghcr.io au dépôt (*Manage Actions access*) si le pull est refusé.
- [ ] Activer *Dependabot alerts* et *Dependabot security updates* (*Settings → Code security*).
- [ ] Planifier `deploy/backup.sh production` (cron) et copier les sauvegardes hors du serveur ; tester une restauration.
