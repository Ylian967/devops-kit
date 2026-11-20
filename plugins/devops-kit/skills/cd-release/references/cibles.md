# cd-release : les deux cibles de déploiement

Dans les deux cas, ce qui tourne sur le serveur est identique : `compose.prod.yaml` + `deploy/` dans un dossier
par environnement (`DEPLOY_DIR`), avec son `.env`. Seule change la façon dont GitHub atteint ce dossier.

| | Runner self-hosted local | VPS en SSH |
|---|---|---|
| Template | `templates/release-runner.yml` | `templates/release-vps.yml` |
| Jobs de déploiement | `runs-on: [self-hosted, deploy]` | `runs-on: ubuntu-latest` + `ssh` |
| Ce qu'il faut sur la machine | Docker + le conteneur runner (`templates/runner/`) | Docker + un utilisateur `deploy` joignable en SSH par clé |
| Ports ouverts sur Internet | aucun (le runner va chercher les jobs chez GitHub) | 22 (SSH), 80 et 443 |
| Secrets GitHub | aucun (`GITHUB_TOKEN` du run) | `SSH_PRIVATE_KEY` par environment |
| Variables d'environment | `DEPLOY_DIR`, `APP_URL` | `DEPLOY_DIR`, `APP_URL`, `SSH_HOST`, `SSH_USER`, `SSH_KNOWN_HOSTS` |
| `DEPLOY_DIR` (convention) | `~/deploy/<repo>-<env>` en chemin absolu | `/opt/<repo>/<env>` |
| `SMOKE_URL` dans `.env` | `https://host.docker.internal:<HTTPS_PORT>/health` (le runner est un conteneur) | `https://localhost:<HTTPS_PORT>/health`, ou le domaine avec Let's Encrypt |
| HTTPS | auto-signé (`gen-cert.sh`), vérifié par `--cacert` | Let's Encrypt (certbot, défi HTTP-01) |
| Bon pour | apprendre, projet perso montré en local, serveur à la maison | application accessible publiquement |

## Runner self-hosted local

- **Une machine, deux environnements** : `~/deploy/monapp-staging` et `~/deploy/monapp-production`, des ports
  différents dans chaque `.env` (ex. staging `HTTP_PORT=8081`, `HTTPS_PORT=8444` ; production 80/443 ou 8082/8443).
- **Même chemin dans le conteneur et sur la machine** (`DEPLOY_ROOT` monté à l'identique) : quand le runner lance
  `docker compose up`, c'est le Docker de la machine qui résout `./deploy/nginx/app.conf` et `./certs`.
- **Socket Docker = root sur la machine.** Conséquences, à dire à l'utilisateur :
  - le runner ne prend que les jobs de `release.yml` (labels `deploy`), jamais de `pull_request` ;
  - dépôt public : exiger l'approbation des workflows des contributeurs externes ;
  - un job peut laisser des fichiers ou une connexion au registre au suivant : `docker logout` en `always()`, et le
    pipeline ne copie que des fichiers versionnés.
- **WSL2** : `DEPLOY_ROOT` sous `/home/...` (pas `/mnt/c`), Docker Desktop avec l'intégration WSL activée ; la
  machine doit rester allumée pour que les déploiements passent.
- Les fichiers que le runner écrit appartiennent à root : `sudo chown -R "$USER" ~/deploy` avant de les éditer.

## VPS en SSH

Préparation du serveur (Debian/Ubuntu), à proposer — **pas** à lancer sans accord, c'est une machine distante :

```bash
# En root sur le VPS
curl -fsSL https://get.docker.com | sh                       # ou le paquet docker.io de la distribution
adduser --disabled-password --gecos '' deploy && usermod -aG docker deploy
install -d -m 700 -o deploy -g deploy ~deploy/.ssh
# coller la clé PUBLIQUE de déploiement dans ~deploy/.ssh/authorized_keys (600, propriétaire deploy)
mkdir -p /opt/monapp/{staging,production} && chown deploy: /opt/monapp/*
# SSH : clés seulement (PasswordAuthentication no, PermitRootLogin no), pare-feu 22/80/443 (ufw)
```

- **La clé de déploiement** est dédiée (jamais la clé personnelle), sans phrase de passe (le job ne peut pas la
  saisir), une par serveur. Option de durcissement : dans `authorized_keys`, préfixer la clé par
  `restrict,from="<plages IP GitHub>"` — les IP des runners GitHub changent souvent, donc rarement tenable ; c'est
  une des raisons de préférer un runner self-hosted sur le VPS lui-même (alors : cible runner, sans SSH).
- **`SSH_KNOWN_HOSTS`** : `ssh-keyscan -t ed25519 <hôte>` ; comparer l'empreinte (`ssh-keygen -lf`) avec celle
  donnée par l'hébergeur ou la console. Ne jamais remplacer par `StrictHostKeyChecking=no`.
- **Un ou deux serveurs** : les variables `SSH_HOST` sont propres à chaque environment ; staging et production
  peuvent être sur le même VPS (deux dossiers, deux jeux de ports, un seul proxy sur 80/443 n'est alors possible que
  pour l'un des deux — l'autre écoute sur 8444) ou sur deux VPS.
- **`docker login` sur le serveur** : le `GITHUB_TOKEN` du job est envoyé par l'entrée standard et expire à la fin du
  job ; `docker logout` est fait en `always()`. Le serveur ne garde aucun jeton GitHub durable.
- **Let's Encrypt** : voir `templates/DEPLOIEMENT.md`, section Certificats. Le port 80 doit être joignable depuis
  Internet pour le défi HTTP-01.
