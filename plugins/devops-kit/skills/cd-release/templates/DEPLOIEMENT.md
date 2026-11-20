# Déploiement de NOM_DU_PROJET

<!-- Modèle devops-kit (bloc cd-release). Remplacer NOM_DU_PROJET, CIBLE, les URL et chemins ; supprimer la
     section de la cible non utilisée. -->

## En bref

| | Staging | Production |
|---|---|---|
| URL | URL_STAGING | URL_PRODUCTION |
| Déclenchement | automatique à chaque merge sur `main` | après approbation (*Review deployments*) |
| Dossier sur le serveur (`DEPLOY_DIR`) | DOSSIER_STAGING | DOSSIER_PRODUCTION |
| Sauvegarde avant déploiement | non | oui (`deploy/backup.sh`) |

```
merge sur main ─▶ release.yml : prepare ─▶ build-push (ghcr.io:<sha>) ─▶ scan (Trivy)
                                   ─▶ deploy-staging ─▶ [approbation] ─▶ deploy-production
```

- **Une image par commit**, taguée par le SHA court (`git rev-parse --short=7 HEAD`), déployée telle quelle en
  staging puis en production. `latest` n'est jamais déployé.
- **La configuration n'est pas dans Git** : chaque environnement a son `.env` sur le serveur (modèle :
  `deploy/env.example`). Le pipeline ne copie que `compose.prod.yaml` et `deploy/`.
- **Rollback automatique** : si le smoke test (`/health` avec la bonne version) échoue, `deploy.sh` remet la version
  précédente et le job reste rouge.

## Contenu d'un dossier d'environnement

| Chemin | Nature | Qui l'écrit |
|---|---|---|
| `compose.prod.yaml`, `deploy/` | code (versionné) | le pipeline, à chaque déploiement |
| `.env` (600) | configuration et secrets | une personne, à la main, une fois |
| `certs/fullchain.pem`, `certs/privkey.pem` | secrets | `deploy/gen-cert.sh` ou certbot |
| `.deployed-tag`, `.previous-tag` | état | `deploy.sh` |
| `backups/` | données | `deploy/backup.sh` |
| volume Docker `<projet>_pgdata` | données | PostgreSQL |

## Gestes courants

```bash
# Quelle version tourne ?
cat DEPLOY_DIR/.deployed-tag ; curl -s URL_PRODUCTION/health

# Rollback (sans rien reconstruire)
gh workflow run release.yml -f tag=<sha-court> -f environment=production
#   ou, sur le serveur, en urgence :  DEPLOY_DIR/deploy/deploy.sh production <sha-court>

# État et logs (sur le serveur, dans DEPLOY_DIR)
export IMAGE_TAG=$(cat .deployed-tag)
docker compose -f compose.prod.yaml ps
docker compose -f compose.prod.yaml logs --tail 100 app

# Sauvegarde et restauration
deploy/backup.sh production && ls -lh backups/
gunzip -c backups/production-AAAAMMJJ-HHMMSS.sql.gz | docker compose -f compose.prod.yaml exec -T db \
  sh -c 'psql -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
```

**Rollback et base de données** : revenir à la version N-1 ne défait pas une migration de la version N. Une migration
doit donc rester compatible avec la version précédente (*expand / contract* : ajouter une colonne d'abord, la
supprimer dans une release ultérieure). Sinon : restaurer la sauvegarde prise avant le déploiement.

## Mise en place (une fois)

### 1. Environments GitHub

*Settings → Environments* :

| Environment | Protection | Variables | Secrets |
|---|---|---|---|
| `staging` | aucune | `DEPLOY_DIR`, `APP_URL` (+ `SSH_*` en cible VPS) | (`SSH_PRIVATE_KEY` en cible VPS) |
| `production` | *Required reviewers* ; *Deployment branches* : `main` seulement | idem | idem |

### 2a. Cible « runner local » (CIBLE)

1. Sur la machine : `mkdir -p ~/deploy/<repo>-staging ~/deploy/<repo>-production`.
2. Runner : copier `runner/` du plugin dans `~/runners/<repo>/`, remplir `.env` (jeton d'enregistrement,
   `DEPLOY_ROOT=/home/<vous>/deploy`), `docker compose up -d`. Attendu dans *Settings → Actions → Runners* :
   `deploy-runner`, **Idle**, labels `self-hosted`, `deploy`.
3. Dépôt public : *Settings → Actions → General → Approval for running fork pull request workflows* →
   **Require approval for all external contributors** (le runner a un accès root à la machine).
4. Fichiers écrits par le runner (root) : `sudo chown -R "$USER" ~/deploy` avant de les éditer à la main.

### 2b. Cible « VPS en SSH » (CIBLE)

1. Sur le VPS : Docker installé, un utilisateur `deploy` dans le groupe `docker`, connexion SSH par clé seulement.
2. Clé dédiée, sur le poste : `ssh-keygen -t ed25519 -N '' -C deploy-<repo> -f deploy_key` ; `deploy_key.pub` dans
   `~deploy/.ssh/authorized_keys` du VPS ; `deploy_key` (privée) dans le secret `SSH_PRIVATE_KEY` de chaque
   environment, puis supprimée du poste.
3. Empreinte du serveur : `ssh-keyscan -t ed25519 <hôte>` → variable `SSH_KNOWN_HOSTS` (vérifier l'empreinte affichée
   par l'hébergeur).
4. `sudo mkdir -p /opt/<repo>/{staging,production} && sudo chown deploy: /opt/<repo>/*`.
5. HTTPS : voir « Certificats » ci-dessous.

### 3. Dans chaque `DEPLOY_DIR`

```bash
cp deploy/env.example "$DEPLOY_DIR/.env" && chmod 600 "$DEPLOY_DIR/.env"   # puis éditer (mot de passe différent par env)
mkdir -p "$DEPLOY_DIR/deploy" && cp deploy/gen-cert.sh "$DEPLOY_DIR/deploy/" && "$DEPLOY_DIR/deploy/gen-cert.sh"
```

### 4. Accès au paquet ghcr.io

Après le premier `build-push` : page du paquet → *Package settings* → *Manage Actions access* : le dépôt doit y être
(rôle *Read* suffit pour le déploiement). Paquet privé : c'est le `GITHUB_TOKEN` du job qui tire l'image.

## Certificats

- **Local / sans domaine** : `deploy/gen-cert.sh` (auto-signé, SAN `localhost`, `host.docker.internal`).
  Le smoke test le vérifie avec `SMOKE_CURL_OPTS=--cacert certs/fullchain.pem`.
- **VPS avec domaine** : Let's Encrypt (certbot, défi HTTP-01 servi par le proxy) :

  ```bash
  cd "$DEPLOY_DIR" && deploy/gen-cert.sh                 # certificat provisoire pour que Nginx démarre
  docker run --rm -v "$PWD/certbot:/var/www/certbot" -v "$PWD/letsencrypt:/etc/letsencrypt" \
    certbot/certbot certonly --webroot -w /var/www/certbot -d app.example.com --agree-tos -m vous@example.com -n
  cp -L letsencrypt/live/app.example.com/{fullchain,privkey}.pem certs/ && chmod 600 certs/privkey.pem
  docker compose -f compose.prod.yaml exec proxy nginx -s reload
  ```
  Renouvellement : même commande avec `renew` à la place de `certonly …`, chaque semaine (cron), puis la copie et le
  reload. Le smoke test vise alors `https://app.example.com/health` sans `--cacert`.

## Dépannage

| Symptôme | Cause probable |
|---|---|
| `deploy-*` reste *Queued* | runner hors ligne, ou labels ≠ `[self-hosted, deploy]` |
| `DEPLOY_DIR absent` / `.env absent` | variable de l'environment manquante, ou étape 3 non faite |
| `denied` au `docker pull` | paquet non relié au dépôt (étape 4) |
| `app` *unhealthy* après `up --wait` | `docker compose logs app` ; souvent `DATABASE_URL` ou un volume `pgdata` créé avec un autre mot de passe |
| Smoke test `SSL certificate problem` | certificat sans le nom visé par `SMOKE_URL` ; `FORCE=1 deploy/gen-cert.sh` |
| `Host key verification failed` (VPS) | `SSH_KNOWN_HOSTS` absent ou serveur réinstallé : refaire `ssh-keyscan` **et** vérifier l'empreinte |
