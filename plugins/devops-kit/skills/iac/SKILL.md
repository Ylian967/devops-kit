---
name: iac
description: Bloc devops-kit « infrastructure as code » — décrit l'environnement staging en OpenTofu (infra/ avec le provider docker : réseau, volume, base PostgreSQL, conteneur de l'application, state hors de Git), ajoute .github/workflows/iac.yml (fmt -check, validate, plan contre le vrai state publié en commentaire de PR, mis à jour à chaque push), fait déployer le staging par tofu apply dans release.yml, reprend le staging Compose existant sans perdre ses données (tofu import), et propose en option un playbook Ansible qui prépare la machine (Docker, utilisateur deploy, dossiers, .env). Deux cibles comme cd-release : runner self-hosted local ou VPS en SSH. À utiliser quand l'utilisateur veut de l'IaC, Terraform ou OpenTofu, voir le plan de son infrastructure dans les PR, décrire son staging en code, ou automatiser la préparation de son serveur avec Ansible.
---

# Bloc iac

Objectif : le staging est **décrit en code** et revu comme du code. Une PR qui touche `infra/` affiche ce que l'apply
va changer ; après le merge, `release.yml` applique ce plan avec la nouvelle image ; le state (qui contient le mot de
passe de la base) ne passe jamais par Git. En option, la préparation du serveur devient un playbook rejouable.

Procédure générale (branche, « rien n'est écrasé », commit, PR) : `${CLAUDE_PLUGIN_ROOT}/skills/devops-apply/SKILL.md`.
Noms partagés (`infra/`, `ansible/`, `iac.yml` et ses jobs, `DEPLOY_DIR`, `<repo>-<env>`, `IMAGE_TAG`, labels du
runner) : `${CLAUDE_PLUGIN_ROOT}/skills/devops-apply/references/conventions.md`.

## Dépendances

- **cd-release** (obligatoire) : images `ghcr.io/<owner>/<repo>:<sha court>`, `release.yml` (son job
  `deploy-staging` est remplacé), environment `staging` avec `DEPLOY_DIR`, et la cible choisie (runner ou VPS). Sans
  lui, il n'y a ni image à déployer ni staging à décrire : proposer cd-release d'abord.
- **docker-dev** (indirecte, via cd-release) : `/health` au format commun et un `HEALTHCHECK` (le conteneur `app` a
  `wait = true` : l'apply échoue si la sonde ne passe pas).
- **git-collab** (conseillé) : la PR est le lieu où se lit le plan.
- **ci** : les jobs d'`iac.yml` ne sont **pas** ajoutés aux checks requis (filtre de chemins, voir l'en-tête du
  template). Ne rien toucher au ruleset.
- Prolonge **cd-release** ; **monitoring** se branche sur le réseau `<repo>-staging_default`, que le bloc garde.

## Signaux de détection

| Élément | Déjà en place si… | Commande |
|---|---|---|
| Code d'infrastructure | `*.tf` quelque part (`infra/`, `terraform/`, `iac/`) | `git ls-files '*.tf' '*.tofu'` |
| Outil | `required_version` / bloc `cloud`, ou `.terraform-version`, `.opentofu-version` | `grep -rn 'required_version\|cloud {' --include=*.tf .` |
| Providers | docker, ou un hébergeur (`aws`, `hcloud`, `scaleway`…) | `grep -rhn 'source *=' --include=*.tf .` |
| Backend du state | `backend "…"` ; un `*.tfstate` **versionné** est un problème à signaler tout de suite (secrets dans l'historique) | `grep -rn 'backend "' --include=*.tf .; git ls-files \| grep -E 'tfstate\|\.terraform/'` |
| Lock file | `.terraform.lock.hcl` versionné | `git ls-files '*.terraform.lock.hcl'` |
| Workflow IaC | un workflow qui lance `tofu`/`terraform` `plan` | `grep -ln 'tofu\|terraform' .github/workflows/*.y*ml` |
| Staging déjà en code | `deploy-staging` de `release.yml` lance `tofu apply` | `grep -n 'tofu apply' .github/workflows/release.yml` |
| Ansible | `ansible/`, `playbook*.yml`, `inventory*` | `git ls-files \| grep -iE 'ansible\|playbook\|inventory'` |
| Outils locaux | `tofu`, `ansible-playbook`, `ansible-lint` | `command -v tofu ansible-playbook ansible-lint` |

- **Terraform déjà utilisé** (pas OpenTofu) : le dire ; garder Terraform (adapter `iac.yml` avec
  `hashicorp/setup-terraform`, épinglé par SHA) ou migrer (`tofu init` lit le même code et le même state), au choix de
  l'utilisateur.
- **Ne s'applique pas** : hébergement PaaS sans conteneur à décrire (Vercel, Netlify, Render…) ; front Next.js + Convex
  sur Vercel (voir `references/stacks.md`). Le dire et ne rien écrire.
- Pas de cd-release : proposer cd-release d'abord.

## Étapes

1. **Cible et options** (AskUserQuestion), en reprenant la cible de cd-release (`grep -c 'self-hosted'
   .github/workflows/release.yml`) ; détail : `references/cibles.md`.
   - *runner local* : templates tels quels, state dans le `DEPLOY_DIR` du staging ;
   - *VPS* : option 1 (runner self-hosted sur le VPS, conseillée : mêmes templates) ou option 2 (`ssh://` + state
     dans un bucket S3 compatible, chiffré) ;
   - Ansible : oui / non (« en option » : le proposer, ne pas l'imposer).
2. **Inventaire** depuis `compose.prod.yaml` : port, healthcheck, variables de l'application, utilisateur et base
   PostgreSQL (`POSTGRES_USER`/`POSTGRES_DB` du `.env`, `app`/`app` par défaut), migration au démarrage ou non
   (`references/stacks.md`), port publié du staging (8081 par défaut, libre ?), propriétaire GitHub en minuscules.
3. **`infra/`** depuis `templates/infra/` : `project`, `image_repository`, `app_port`, `app_healthcheck`, variables de
   l'application dans `env`, `locals.db_user`/`db_name` ; adaptations de la stack (`references/stacks.md`) ; variante
   VPS option 2 (`references/cibles.md`). Puis, dans `infra/` :
   ```bash
   tofu init -backend=false && tofu fmt -recursive && tofu validate
   tofu providers lock -platform=linux_amd64 -platform=linux_arm64 -platform=darwin_amd64 \
     -platform=darwin_arm64 -platform=windows_amd64        # .terraform.lock.hcl : à committer
   ```
4. **`.gitignore`** : les entrées de `references/cibles.md` (state, `.terraform/`, plans, `*.tfvars`,
   `ansible/inventory.ini`). Vérifier qu'aucun state n'est déjà suivi par Git.
5. **`.github/workflows/iac.yml`** depuis `templates/iac.yml` : version de `tofu` (`tofu version` du poste), chemins.
   Garder `permissions: {}` et les permissions par job (`pull-requests: write` seulement dans `comment`), les actions
   épinglées par SHA (à jour : `gh api repos/<action>/releases/latest --jq .tag_name` puis
   `git ls-remote https://github.com/<action> 'refs/tags/<tag>^{}' 'refs/tags/<tag>'`, ligne `^{}` si elle existe),
   `concurrency`, `timeout-minutes`, la condition anti-fork du job `plan`, et les noms `fmt`, `validate`, `plan`
   (+ `comment`). `.github/actionlint.yaml` doit déclarer le label `deploy` (déjà là avec cd-release, cible runner).
6. **`release.yml`, job `deploy-staging`** : le remplacer par `templates/deploy-staging.yml` (règle « rien n'est
   écrasé » : diff du job complet, accord). D'abord recopier dans `deploy-production` les steps désignés par les ancres
   YAML de l'ancien `deploy-staging`, sans les `&…` (voir l'en-tête du fragment). Variante VPS option 2 :
   `references/cibles.md`. Le `TOFU_VERSION` doit être le même que dans `iac.yml`.
7. **Ansible** (si choisi) : `ansible/site.yml`, `ansible/inventory.ini.example`, `ansible/templates/env.j2` depuis
   `templates/ansible/` : `vars` du play (projet, image, dossiers `DEPLOY_DIR`, ports, `preparer_systeme`) ;
   `env.j2` aligné sur `deploy/env.example` du projet (mêmes clés, mêmes variables de l'application).
8. **Documentation** : section « Staging en OpenTofu » dans `docs/DEPLOIEMENT.md` (créé par cd-release) : où vit le
   state, comment lire le plan d'une PR, retour arrière, procédure de reprise (étape 10). Pas de nouveau fichier.
9. **Commit** : `build: décrit le staging en OpenTofu et planifie les PR d'infrastructure`, puis PR si demandé. Le
   corps de PR liste les gestes manuels, en premier la reprise du staging (étape 10) qui doit être faite **avant** le
   merge : sinon le premier `deploy-staging` OpenTofu se heurte aux conteneurs Compose.
10. **Reprise du staging Compose** (sur la machine du staging, hors dépôt : seulement si l'utilisateur le demande et
    que c'est le poste local ; sinon, lui donner les commandes). Le volume et ses données sont **gardés** :
    ```bash
    cd infra
    export DEPLOY_DIR=~/deploy/<repo>-staging                 # VPS option 1 : /opt/<repo>/staging, sur le VPS
    tofu init -backend-config="path=$DEPLOY_DIR/terraform.tfstate"
    export TF_VAR_image_tag="$(cat "$DEPLOY_DIR/.deployed-tag")"
    # paquet ghcr.io privé : export TF_VAR_ghcr_username=<compte> TF_VAR_ghcr_token=<PAT read:packages>
    (cd "$DEPLOY_DIR" && IMAGE_TAG="$TF_VAR_image_tag" docker compose -f compose.prod.yaml down)   # PAS de -v
    tofu import docker_volume.pgdata <repo>-staging_pgdata
    tofu import random_password.db "$(sed -n 's/^POSTGRES_PASSWORD=//p' "$DEPLOY_DIR/.env")"
    tofu plan     # LIRE : rien ne doit détruire le volume ; random_password sans changement
    tofu apply
    curl -fsS "$(tofu output -raw health_url)"                # "status":"ok", la même version
    tofu plan     # attendu : No changes
    ```
    Jamais d'apply d'un plan qui remplace `docker_volume.pgdata`. Staging neuf (pas de Compose avant) : seulement
    `tofu init …` puis `tofu apply -var image_tag=<sha>`. Variante VPS option 2 : mêmes commandes depuis le poste, avec
    `TF_VAR_docker_host=ssh://deploy@<hôte>`, les identifiants du bucket et `TF_VAR_state_passphrase`.
11. **Côté GitHub** (accord explicite, après le push) : rien d'obligatoire pour la cible runner (`DEPLOY_DIR` existe
    déjà dans l'environment `staging`) ; mettre à jour `APP_URL` du staging
    (`gh variable set APP_URL --env staging --body "http://127.0.0.1:8081"`). VPS option 2 : les secrets
    `STATE_*` sont des gestes manuels (jamais saisis par Claude).

## Fichiers produits

| Fichier | Source |
|---|---|
| `infra/versions.tf`, `providers.tf`, `variables.tf`, `main.tf`, `outputs.tf`, `terraform.tfvars.example` | `templates/infra/` |
| `infra/.terraform.lock.hcl` | `tofu providers lock` (étape 3) |
| `.github/workflows/iac.yml` | `templates/iac.yml` |
| `.github/workflows/release.yml` (job `deploy-staging` remplacé, ancres de `deploy-production` dépliées) | `templates/deploy-staging.yml` |
| `.gitignore` (ajouts) | `references/cibles.md` |
| `docs/DEPLOIEMENT.md` (section ajoutée) | étape 8 |
| (option) `ansible/site.yml`, `ansible/inventory.ini.example`, `ansible/templates/env.j2` | `templates/ansible/` |
| (hors dépôt) `$DEPLOY_DIR/terraform.tfstate` du staging, ou l'objet du bucket (VPS option 2) | étape 10 |

## Vérification

```bash
cd infra
tofu fmt -check -recursive                                   # rien ne s'affiche
tofu init -backend=false -lockfile=readonly && tofu validate # « Success! The configuration is valid. »
cd ..
docker run --rm -v "$PWD":/repo -w /repo rhysd/actionlint:1.7.12 -color   # iac.yml et release.yml : rien
git ls-files | grep -E 'tfstate|\.terraform/|tfplan|\.tfvars$'           # vide
git check-ignore -q infra/terraform.tfstate infra/.terraform && echo ignorés
# Ansible (si choisi)
ansible-playbook -i ansible/inventory.ini.example ansible/site.yml --syntax-check
command -v ansible-lint >/dev/null && ansible-lint ansible/              # si installé
```

`tofu` absent du poste : l'installer (https://opentofu.org/docs/intro/install/) ; à défaut, les jobs `fmt` et
`validate` de la PR font la même vérification. Ansible absent : `pipx install ansible-core` (et
`pipx run ansible-lint ansible/`).

Après la reprise (étape 10) : `tofu plan` → `No changes`. Après le push : la PR affiche le commentaire « Plan OpenTofu :
staging » (`No changes` si seul le workflow change) ; un second push **met à jour** ce commentaire. Après le merge :
*Actions → Release* — `deploy-staging` affiche `Apply complete!`, puis `curl` sur `health_url` : la nouvelle version.
Preuve de dérive (à proposer) : `docker rm -f <repo>-staging-app`, puis *Actions → IaC → Run workflow* : `plan`
échoue (« Dérive ») ; relancer la dernière release pour corriger. Ansible : deux passages, le second `changed=0`.

## Gestes manuels à laisser à l'utilisateur

- [ ] **Avant le merge** : reprendre le staging Compose (étape 10) — `docker compose down` sans `-v`, `tofu import`
      du volume et du mot de passe, lire le plan, `tofu apply`, `tofu plan` → `No changes`.
- [ ] Le state : ne jamais le committer, ne jamais le supprimer ; le sauvegarder avec les sauvegardes (cible runner,
      il vit sur une seule machine). Un verrou orphelin après un job annulé : `tofu force-unlock <ID>`, en sachant
      qu'aucun apply ne tourne.
- [ ] *Settings → Actions → General* : approbation des workflows **de tous les contributeurs externes** (le job `plan`
      tourne sur le runner self-hosted, qui a le socket Docker).
- [ ] Ne **pas** ajouter `fmt`, `validate`, `plan` aux checks requis du ruleset (filtre de chemins : une PR sans
      changement dans `infra/` serait bloquée).
- [ ] Mettre à jour `APP_URL` de l'environment `staging` (le staging OpenTofu n'a pas de proxy HTTPS).
- [ ] VPS option 1 : installer le runner de cd-release sur le VPS (jeton d'enregistrement, `DEPLOY_ROOT=/opt/<repo>`).
- [ ] VPS option 2 : créer le bucket (privé, versionnage activé) et une clé limitée à ce bucket ; secrets
      `STATE_ACCESS_KEY_ID`, `STATE_SECRET_ACCESS_KEY`, `STATE_PASSPHRASE` (≥ 16 caractères, gardée aussi dans un
      gestionnaire de mots de passe : perdue = state illisible) dans l'environment `staging`.
- [ ] Ansible (VPS) : générer la clé de déploiement (`ssh-keygen -t ed25519 -N '' -f deploy_key`), lancer le playbook
      avec la clé **publique**, puis durcir SSH (`PasswordAuthentication no`, `PermitRootLogin no`) et le pare-feu
      (22, 80, 443) à la main, en gardant une session ouverte pendant le test.
- [ ] Mises à jour de providers : `tofu init -upgrade`, puis `tofu providers lock` pour les cinq plateformes, dans
      une PR (le plan dira ce qui change).
