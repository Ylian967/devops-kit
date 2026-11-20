---
name: docker-dev
description: Bloc devops-kit « Docker pour le développement » — conteneurise l'application avec un Dockerfile multi-stage (utilisateur non root, version d'image précise, APP_VERSION en argument de build), un .dockerignore, un compose.yaml de dev (application + PostgreSQL, healthchecks, base non exposée), une route GET /health (statut, état de la base, version, environnement ; 503 si la base ne répond pas), un .env.example et .env dans .gitignore. Variantes Node/Next.js, Next.js + Convex, Java (Maven, Gradle), Rust, Elixir. À utiliser quand l'utilisateur veut dockeriser son projet, lancer son environnement de dev en une commande, ajouter un healthcheck ou une route /health, ou préparer le terrain pour le déploiement (bloc cd-release).
---

# Bloc docker-dev

Objectif : `docker compose up -d --build` démarre l'application et sa base sur n'importe quel poste, sans rien
installer d'autre que Docker ; l'image produite est celle que le bloc `cd-release` publiera et déploiera.

Procédure générale (branche, « rien n'est écrasé », commit, PR) : `${CLAUDE_PLUGIN_ROOT}/skills/devops-apply/SKILL.md`.
Noms partagés (`app`, `db`, `PORT`, `DATABASE_URL`, `APP_ENV`, `APP_VERSION`, format de `/health`) :
`${CLAUDE_PLUGIN_ROOT}/skills/devops-apply/references/conventions.md`.

## Dépendances

- Aucune obligatoire.
- Après **ci** : le job `docker-build` de `ci.yml` (supprimé faute de Dockerfile) peut être ajouté ; le proposer.
- Requis par **cd-release** (image, `/health`, healthcheck) et **monitoring** (réseau Compose, `/metrics` à côté de
  `/health`).

## Signaux de détection

| Élément | Déjà en place si… | Commande |
|---|---|---|
| Dockerfile | `Dockerfile` à la racine ou dans chaque composant | `ls Dockerfile* */Dockerfile 2>/dev/null` |
| Multi-stage | au moins deux `FROM` | `grep -c '^FROM' Dockerfile` |
| Non root | une ligne `USER` qui n'est pas `root` / `0` dans la dernière étape | `grep -n '^USER' Dockerfile` |
| Version d'image précise | ni `latest`, ni tag absent | `grep -n '^FROM\|^ARG .*IMAGE' Dockerfile` |
| `.dockerignore` | présent et exclut `.env`, `.git`, dépendances | `cat .dockerignore` |
| Compose de dev | `compose.yaml`, `compose.yml`, `docker-compose.y*ml` | `ls` ; ancien nom `docker-compose.yml` : proposer de renommer |
| Healthchecks | `healthcheck:` sur `db` et (Dockerfile ou compose) sur l'application ; `depends_on … condition: service_healthy` | `grep -n 'healthcheck\|service_healthy' compose*.y*ml Dockerfile` |
| Base publiée | `ports:` sur le service de base sans `127.0.0.1:` | à corriger (exposée sur tout le réseau local) |
| `/health` | une route `/health` (ou `/healthz`, `/actuator/health`) | `grep -rn "health" src lib app 2>/dev/null \| head` |
| `.env.example` / `.gitignore` | `.env.example` versionné ; `.env` ignoré | `git check-ignore -q .env && echo ignoré` ; `git ls-files .env` (doit être vide) |

- **Ne s'applique pas** (le dire) : bibliothèque publiée sans exécutable, site 100 % statique hébergé ailleurs
  (Vercel, Netlify) sans serveur à déployer soi-même, CLI.
- **Next.js + Convex** : s'applique en partie (image du front Next.js, `/health` sans base) ; pas de service `db`.
  Voir `references/nextjs-convex.md`.
- `.env` **déjà versionné** (`git ls-files .env` non vide) : c'est un incident, le signaler en premier (secret à
  changer, retrait de l'index) — l'historique se traite avec le bloc `devsecops`.

## Étapes

1. **Stack et référence** :

   | Stack | Dockerfile | Référence |
   |---|---|---|
   | Node (API) | `templates/Dockerfile.node` | `references/node.md` |
   | Next.js | `templates/Dockerfile.nextjs` | `references/node.md` (section Next.js) |
   | Next.js + Convex | `templates/Dockerfile.nextjs` | `references/nextjs-convex.md` |
   | Java Maven / Gradle (Spring Boot) | `templates/Dockerfile.java-maven` / `Dockerfile.java-gradle` | `references/java.md` |
   | Rust | `templates/Dockerfile.rust` | `references/rust.md` |
   | Elixir (Phoenix) | `templates/Dockerfile.elixir` | `references/elixir.md` |

   Monorepo : un Dockerfile par composant (`api/Dockerfile`, `front/Dockerfile`), un service par composant dans le
   même `compose.yaml`.
2. **Inventaire** : commande de démarrage réelle, port lu (`PORT` ?), variables lues (`DATABASE_URL` ou autres noms :
   garder ceux du projet), dossier de sortie du build, version du runtime (`.nvmrc`, `engines`, `rust-toolchain.toml`,
   `<java.version>`, `.tool-versions`) : l'image prend **la même version majeure** que la CI.
3. **Route `/health`** si elle manque ou ne suit pas la convention (format exact dans `conventions.md`). Code à
   ajouter : section *Route /health* de la référence de la stack. La vérification de la base doit être **réelle**
   (`SELECT 1` avec un délai court, 1 à 2 s) : un `/health` qui renvoie toujours 200 rend le healthcheck, le smoke test
   et la supervision aveugles. Ajouter un test unitaire de la route (200 base OK, 503 base KO) si le projet a des tests.
   Diff montré, accord demandé : on touche au code de l'application.
4. **`Dockerfile`** depuis le template : supprimer l'étape `build` s'il n'y a rien à compiler, adapter version,
   dossiers copiés, commande de démarrage, port ; garder `USER` numérique non root, `ARG APP_VERSION` après les
   `COPY`, forme exec de `CMD`, `HEALTHCHECK`. Mettre à jour le tag d'image vers la dernière version corrective de la
   même branche si le template est en retard (`docker pull` ou la page Docker Hub).
5. **`.dockerignore`** depuis `templates/dockerignore` : garder la partie commune et la section de la stack.
6. **`compose.yaml`** depuis `templates/compose.yaml` : `name: <repo>-local`, variables réelles de l'application,
   port de la stack ; supprimer `db` et `pgdata` si le projet n'a pas de base ; autre moteur (MySQL, Mongo) : changer
   l'image, le volume et le healthcheck (référence de la stack). Un `docker-compose.yml` existant : diff et fusion,
   jamais de remplacement silencieux.
7. **`.env.example`** depuis `templates/env.example` (valeurs factices) ; ajouter `.env` au `.gitignore` s'il n'y est
   pas (et `!.env.example` si le `.gitignore` contient `.env*`).
8. **README du projet** : proposer (accord) une section « Lancer en local avec Docker » de trois lignes :
   `cp .env.example .env`, `docker compose up -d --build`, `curl http://127.0.0.1:<port>/health`.
9. Si `ci.yml` existe sans job `docker-build` : proposer de l'ajouter (bloc `ci`, `templates/ci-<stack>.yml`).
10. **Commit** : `build: conteneurise l'application pour le développement` (+ `feat: ajoute la route /health` à part
    si le code de l'application a changé).

## Fichiers produits

| Fichier | Source |
|---|---|
| `Dockerfile` (ou `<composant>/Dockerfile`) | `templates/Dockerfile.<stack>` |
| `.dockerignore` | `templates/dockerignore` |
| `compose.yaml` | `templates/compose.yaml` |
| `.env.example` | `templates/env.example` |
| `.gitignore` (ajout de `.env`) | — |
| Route `/health` + son test | `references/<stack>.md` |

## Vérification

```bash
docker compose config -q                                     # syntaxe et variables du compose
docker run --rm -i hadolint/hadolint:v2.15.1 < Dockerfile    # bonnes pratiques du Dockerfile
docker build --build-arg APP_VERSION=test -t devops-kit-test .
docker run --rm --entrypoint id devops-kit-test             # uid ≠ 0 (Rust distroless : voir references/rust.md)
docker compose up -d --build --wait                         # --wait : échoue si un healthcheck ne passe pas
curl -fsS http://127.0.0.1:${APP_PORT:-3000}/health         # {"status":"ok","db":"up","version":"dev","env":"local"}
docker compose stop db && sleep 12 && curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:${APP_PORT:-3000}/health   # 503
docker compose ps                                           # app passe « unhealthy »
docker compose start db && docker compose down               # on range (le volume reste)
git check-ignore -q .env && echo ".env ignoré"
```

Docker absent ou arrêté : le dire dans le rapport, ne lancer que `docker compose config` si le CLI est là, et laisser
les autres commandes à l'utilisateur.

## Gestes manuels à laisser à l'utilisateur

- [ ] `cp .env.example .env` sur chaque poste (le `.env` n'est jamais versionné).
- [ ] Si `.env` a déjà été commité : changer les secrets qu'il contenait, puis `git rm --cached .env`.
- [ ] Mettre à jour les images de base régulièrement (Dependabot `docker`, ajouté par le bloc `cd-release`).
- [ ] Docker Desktop sous WSL2 : activer *Settings → Resources → WSL integration* pour la distribution utilisée.
