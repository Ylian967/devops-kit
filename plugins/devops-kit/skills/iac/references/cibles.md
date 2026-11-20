# iac : les deux cibles, le state, le partage des rôles avec cd-release

## Qui fait quoi

| | Staging | Production |
|---|---|---|
| Décrit par | `infra/*.tf` (OpenTofu) | `compose.prod.yaml` (cd-release) |
| Déployé par | `release.yml` → `deploy-staging` : `tofu plan -out` puis `tofu apply tfplan` | `release.yml` → `deploy-production` : `deploy/deploy.sh` (inchangé) |
| Revu en PR | `iac.yml` : plan publié en commentaire | — |
| Contenu | `db` + `app`, sans proxy, port publié sur `127.0.0.1:8081` | `db` + `app` + `proxy` HTTPS |
| Retour arrière | dernier step de `deploy-staging` (ré-apply du tag précédent) ou *Run workflow* avec un tag | `deploy.sh` (automatique) ou *Run workflow* |

**Un seul outil par environnement.** Le staging n'est plus jamais lancé par `docker compose -p <repo>-staging` :
OpenTofu et Compose se disputeraient les mêmes conteneurs. Garde-fou naturel : Compose refuse un réseau
`<repo>-staging_default` qu'il n'a pas créé, et OpenTofu refuse d'en créer un qui existe déjà.

Pourquoi la production reste en Compose : `deploy.sh` sauvegarde la base avant chaque déploiement et revient seul à la
version précédente ; le staging sert à apprendre et à prouver le workflow plan → revue → apply sans risquer les données
de production. Passer la production en OpenTofu : même code, `environment = "production"`, un second state ; à
proposer seulement quand le staging tourne depuis un moment.

Les noms restent ceux de Compose (`<repo>-staging_default`, `<repo>-staging_pgdata`, alias `db` et `app`) : le bloc
monitoring se branche pareil, et le volume du staging Compose est **importé** au lieu d'être recréé.

## Ce qui n'est jamais versionné

`.gitignore` à la racine :

```gitignore
# OpenTofu : state (mot de passe de la base en clair), binaires des providers, plans, variables locales
.terraform/
*.tfstate
*.tfstate.*
*.tfplan
tfplan
*.tfvars
# Ansible : adresse réelle du serveur
ansible/inventory.ini
```

`infra/.terraform.lock.hcl` **est** versionné (versions exactes et empreintes des providers, comme un lock npm), et
`terraform.tfvars.example` aussi (`*.tfvars` ne l'attrape pas).

## Cible « runner self-hosted local » (template par défaut)

| Élément | Valeur |
|---|---|
| Templates | `iac.yml`, `deploy-staging.yml` tels quels |
| Où tourne `plan` | `[self-hosted, deploy]` : le seul endroit qui voit le Docker et le state du staging |
| Daemon Docker | socket local (`docker_host = null`), déjà monté dans le conteneur du runner |
| State | `$DEPLOY_DIR/terraform.tfstate` du staging (`tofu init -backend-config="path=…"`), backend `local` |
| Verrou | fichier local : `-lock-timeout=120s` fait attendre un plan pendant un apply |
| Secrets GitHub | aucun |
| Variables | `DEPLOY_DIR`, `APP_URL` (`http://127.0.0.1:8081`) dans l'environment `staging` (déjà là avec cd-release) |
| Sauvegarde du state | il vit sur une seule machine : le copier avec les sauvegardes (`cp "$DEPLOY_DIR/terraform.tfstate" …`) ; perdu, il se reconstruit par `tofu import` (réseau, volume, conteneurs, `random_password` depuis le mot de passe connu) |

Le runner prend ici des jobs de `pull_request`, ce que cd-release excluait : seulement le job `plan` d'`iac.yml`,
seulement pour les PR du dépôt (pas les forks), sans aucun secret, avec un `GITHUB_TOKEN` en lecture. Exiger dans
*Settings → Actions → General* l'approbation des workflows de **tous** les contributeurs externes : une PR de fork
pourrait sinon modifier `iac.yml` pour retirer la condition. Dépôt public qui accepte des contributions : préférer
retirer le job `plan` (garder `fmt` et `validate`) et planifier à la main en local.

Le smoke test de cd-release n'est pas repris pour le staging : le port est publié sur `127.0.0.1` de la machine, que le
conteneur du runner ne joint pas. `wait = true` sur le conteneur `app` joue ce rôle (healthcheck sur `/health` dans le
conteneur qui porte `APP_VERSION` = le tag) ; l'apply échoue s'il ne passe pas.

`setup-opentofu` télécharge `tofu` sur le runner à chaque job (le conteneur `myoung34/github-runner` ne l'a pas) ; il
a besoin de `unzip`, présent dans cette image.

## Cible « VPS en SSH »

Deux façons, au choix de l'utilisateur. **Ne pas créer le VPS en OpenTofu par défaut** : le VPS existe déjà (créé à la
main chez l'hébergeur, comme le suppose cd-release). Un provider d'hébergeur (`hetznercloud/hcloud`, `scaleway/scaleway`,
`ovh/ovh`…) est une évolution possible, mais il demande un jeton d'API capable de détruire le serveur de production :
hors du périmètre de ce bloc.

### Option 1 (conseillée) : un runner self-hosted sur le VPS

Installer le runner de cd-release (`cd-release/templates/runner/`) sur le VPS, avec `DEPLOY_ROOT=/opt/<repo>`. Le
bloc iac est alors **identique** à la cible runner : mêmes templates, state dans `/opt/<repo>/staging/terraform.tfstate`,
aucun secret, aucun backend distant. `release.yml` peut garder le SSH pour la production. Le runner ne fait que des
connexions sortantes : aucun port en plus.

### Option 2 : sans runner, Docker via `ssh://` et state distant

Tout tourne sur `ubuntu-latest`. Le provider docker joint le VPS par `ssh://deploy@<hôte>` (il lance
`ssh … docker system dial-stdio` : CLI docker requis sur le VPS, utilisateur dans le groupe docker). La machine du job
est jetable : le state ne peut pas y vivre, il va dans un **bucket S3 compatible** (Scaleway, OVH, Hetzner Object
Storage, Cloudflare R2, AWS…), **chiffré côté client** par OpenTofu (le state contient le mot de passe de la base).

`infra/versions.tf` : remplacer `backend "local" {}` par (et `required_version = ">= 1.10.0"`, pour `use_lockfile`) :

```hcl
  # State dans un bucket S3 compatible, verrou par fichier .tflock à côté.
  # Identifiants : AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (secrets GitHub, jamais ici).
  backend "s3" {
    bucket       = "monapp-tfstate"                       # REMPLACER : bucket privé, versionnage activé
    key          = "staging/terraform.tfstate"            # un fichier par environnement
    region       = "fr-par"                               # REMPLACER : région de l'hébergeur
    endpoints    = { s3 = "https://s3.fr-par.scw.cloud" } # REMPLACER : point d'accès S3 de l'hébergeur
    use_lockfile = true                                   # verrou natif (OpenTofu 1.10+)
    # Hors AWS : pas de STS, pas de région AWS, pas de somme de contrôle AWS
    use_path_style              = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
  }

  # Chiffrement du state et des plans AVANT l'envoi : l'hébergeur du bucket ne lit
  # pas le mot de passe de la base. Phrase perdue = state illisible (la garder
  # dans un gestionnaire de mots de passe).
  encryption {
    key_provider "pbkdf2" "state" {
      passphrase = var.state_passphrase # 16 caractères minimum
    }
    method "aes_gcm" "state" {
      keys = key_provider.pbkdf2.state
    }
    state {
      method   = method.aes_gcm.state
      enforced = true # refuse d'écrire un state en clair
    }
    plan {
      method   = method.aes_gcm.state
      enforced = true
    }
  }
```

`infra/variables.tf` : ajouter

```hcl
variable "state_passphrase" {
  description = "Phrase de chiffrement du state (TF_VAR_state_passphrase, secret GitHub STATE_PASSPHRASE)."
  type        = string
  sensitive   = true
}
```

Dans `iac.yml` (job `plan`) **et** dans `deploy-staging` :

```yaml
    runs-on: ubuntu-latest # à la place de [self-hosted, deploy]
    env:
      SSH_TARGET: ${{ vars.SSH_USER }}@${{ vars.SSH_HOST }}
      TF_VAR_docker_host: ssh://${{ vars.SSH_USER }}@${{ vars.SSH_HOST }}
      AWS_ACCESS_KEY_ID: ${{ secrets.STATE_ACCESS_KEY_ID }} # clé du bucket, droits sur CE bucket seulement
      AWS_SECRET_ACCESS_KEY: ${{ secrets.STATE_SECRET_ACCESS_KEY }}
      TF_VAR_state_passphrase: ${{ secrets.STATE_PASSPHRASE }}
      # (garder DEPLOY_DIR, TAG, TF_* et TF_VAR_ghcr_* déjà présents)
    steps:
      # … checkout, setup-opentofu, puis AVANT tofu init :
      # Clé privée dans un fichier 600 ; known_hosts fourni : on VÉRIFIE l'identité
      # du serveur (jamais StrictHostKeyChecking=no).
      - name: Préparer SSH (le provider docker passe par ssh://)
        env:
          SSH_PRIVATE_KEY: ${{ secrets.SSH_PRIVATE_KEY }}
          SSH_KNOWN_HOSTS: ${{ vars.SSH_KNOWN_HOSTS }}
        run: |
          install -m 700 -d ~/.ssh
          printf '%s\n' "$SSH_PRIVATE_KEY" > ~/.ssh/deploy_key && chmod 600 ~/.ssh/deploy_key
          printf '%s\n' "$SSH_KNOWN_HOSTS" > ~/.ssh/known_hosts
          printf 'Host %s\n  IdentityFile ~/.ssh/deploy_key\n  IdentitiesOnly yes\n  BatchMode yes\n' "${SSH_TARGET#*@}" > ~/.ssh/config
          ssh "$SSH_TARGET" docker version --format 'Docker {{.Server.Version}} joignable'
      # tofu init : plus de -backend-config, le backend s3 est décrit dans versions.tf
      - run: tofu init -lockfile=readonly
      # … steps inchangés, puis en dernier :
      - name: Effacer la clé
        if: always()
        run: rm -f ~/.ssh/deploy_key
```

Dans le job `plan`, le repli `cat "$DEPLOY_DIR/.deployed-tag"` devient
`ssh "$SSH_TARGET" cat "$DEPLOY_DIR/.deployed-tag"` (il ne sert qu'avant la migration).

Le prix de l'option 2 : le job `plan` d'une PR reçoit la clé SSH du serveur (utilisateur du groupe docker = root) et
les identifiants du bucket. Acceptable pour un dépôt où seul le propriétaire ouvre des PR ; sinon, option 1.

## Ansible : préparer la machine

`ansible/site.yml` refait de façon idempotente les gestes « serveur » de cd-release :

| Cible | Inventaire | `preparer_systeme` | Fait |
|---|---|---|---|
| VPS | `vps ansible_host=… ansible_user=root` | `true` | Docker (script officiel), utilisateur `deploy` (groupe docker, compte verrouillé, clé publique de déploiement), `/opt/<repo>/<env>`, `.env` de production |
| Runner local | `local ansible_connection=local` | `false` | `~/deploy/<repo>-<env>`, `.env` de production, sans sudo |

- Le `.env` est rendu **une seule fois** (`force: false`) avec un mot de passe aléatoire : un `.env` existant n'est
  jamais réécrit (il contient le mot de passe qui a initialisé le volume). Le staging OpenTofu n'a pas de `.env`.
- Pas de durcissement SSH ni de pare-feu dans le playbook (une erreur enferme dehors) : geste manuel listé.
- `--check --diff` d'abord, puis deux passages : le second doit finir avec `changed=0`.
