# iac : variantes par stack

Ce qui change d'une stack à l'autre tient dans `infra/variables.tf` (`app_port`, `app_healthcheck`) et dans la liste
`env` du conteneur `app` de `infra/main.tf`. Le reste (réseau, volume, base, `iac.yml`, `deploy-staging`) est commun.
Reprendre **les mêmes valeurs que `compose.prod.yaml`** (cd-release) : le staging OpenTofu et la production Compose
doivent faire tourner la même image avec la même configuration, seules les valeurs changent.

| Stack | `app_port` | `app_healthcheck` | `start_period` / `wait_timeout` |
|---|---|---|---|
| Node (API) | 3000 | défaut du template (`node -e "fetch(…/health)"`) | 10s / 120 |
| Next.js | 3000 | idem Node | 10s / 120 |
| Next.js + Convex | 3000 | idem Node | 10s / 120 |
| Java Spring (Maven, Gradle) | 8080 | `["CMD-SHELL", "curl -fsS -o /dev/null http://127.0.0.1:8080/health"]` | 60s / 300 |
| Rust | 8080 | `["CMD", "/app/server", "healthcheck"]` | 10s / 120 |
| Elixir (Phoenix) | 4000 | `["CMD", "bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/4000 && printf 'GET /health HTTP/1.0\\r\\n\\r\\n' >&3 && head -n1 <&3 \| grep -q ' 200 '"]` | 30s / 180 |

Le healthcheck du `Dockerfile` (bloc docker-dev) et celui de `main.tf` doivent être la même sonde : `wait = true` en a
besoin, et c'est elle qui fait échouer l'apply d'une version cassée. Si l'image n'a pas l'outil (`curl` absent d'une
image Java distroless, par exemple), reprendre exactement la commande du `HEALTHCHECK` du Dockerfile.

Migrations : pas de `MIGRATE_CMD` côté OpenTofu. Le staging doit migrer **au démarrage** de l'application (Flyway,
Liquibase, `sqlx::migrate!`, `bin/migrate` dans le `CMD`, `prisma migrate deploy && node server.js`). Si le projet
migre seulement par `MIGRATE_CMD` dans `deploy.sh`, le dire : le staging OpenTofu démarrerait sur un schéma ancien.
Proposer de lancer la migration au démarrage de l'image (le plus simple), ou un step `docker run --rm --network
<repo>-staging_default <image>:<tag> <commande>` avant l'apply dans `deploy-staging`.

## Node / Next.js

- Rien à changer au template si le port est 3000 et `/health` existe.
- Next.js : `NEXT_PUBLIC_*` est figé au build ; rien à passer dans `env` pour ces variables.
- Variables serveur de l'application : une ligne `"NOM=${var.nom}"` par variable dans `env`, et une `variable`
  correspondante (`sensitive = true` si c'est un secret, valeur par `TF_VAR_nom` depuis un secret de l'environment
  `staging` dans `deploy-staging` **et** dans le job `plan`, sinon le plan d'une PR voudrait la changer).

## Next.js + Convex

| Élément du template | Avec Convex | Pourquoi |
|---|---|---|
| `docker_container.db`, `docker_image.db`, `docker_volume.pgdata`, `random_password.db`, `locals.db_*` | **Supprimés** | La base est hébergée par Convex |
| `DATABASE_URL` dans `env`, `depends_on = [docker_container.db]` | **Supprimés** | Idem |
| Provider `random` dans `versions.tf` | **Supprimé** (plus de mot de passe à générer) ; régénérer le lock file | |
| Provider Convex | **Aucun** : pas de provider OpenTofu officiel pour Convex (vérifier sur search.opentofu.org au moment d'appliquer ; ne jamais installer un provider communautaire sans le montrer à l'utilisateur) | Les déploiements Convex (staging, production) se créent dans le tableau de bord ; les fonctions sont poussées par `npx convex deploy` dans `release.yml` (cd-release), avant l'apply |
| `NEXT_PUBLIC_CONVEX_URL` | Figée dans l'image au build | Si staging et production ont deux déploiements Convex, cd-release construit une image par environnement : `image_tag` reste le SHA court, mais `image_repository` ou le tag doit désigner l'image du staging (adapter la validation de `image_tag` si le tag devient `<sha>-staging`) |
| Front hébergé sur Vercel | **Le bloc ne s'applique pas** : il n'y a ni conteneur ni Docker à décrire | Le dire, et ne rien écrire |

Ce qui reste avec Convex : un seul conteneur `app` (le front Next.js), son réseau, son port publié. C'est peu : proposer
le bloc surtout pour apprendre le workflow plan → revue → apply, et le dire.

## Java (Maven, Gradle)

- `env` : remplacer `DATABASE_URL` par
  `"SPRING_DATASOURCE_URL=jdbc:postgresql://db:5432/${local.db_name}"`,
  `"SPRING_DATASOURCE_USERNAME=${local.db_user}"`, `"SPRING_DATASOURCE_PASSWORD=${local.db_password}"`.
- Démarrage lent de la JVM : `start_period = "60s"`, `wait_timeout = 300` sur `app`.
- `PORT` : Spring lit `SERVER_PORT` ; garder `PORT` seulement si `application.properties` fait
  `server.port=${PORT:8080}` (convention devops-kit), sinon ajouter `"SERVER_PORT=${var.app_port}"`.

## Rust

- `DATABASE_URL` au format `postgres://` : celui du template convient.
- Image distroless : pas de shell, donc pas de `CMD-SHELL` ; la sonde est une sous-commande du binaire
  (`/app/server healthcheck`), comme dans le Dockerfile.

## Elixir (Phoenix)

- `env` en plus : `"SECRET_KEY_BASE=${random_password.secret_key_base.result}"`, `"PHX_HOST=localhost"`,
  `"PHX_SERVER=true"`, et `DATABASE_URL` au format `ecto://${local.db_user}:${local.db_password}@db/${local.db_name}`.
- Générer la clé comme le mot de passe (elle vit dans le state, comme lui) :

  ```hcl
  resource "random_password" "secret_key_base" {
    length  = 64
    special = false # mix phx.gen.secret produit aussi 64 caractères alphanumériques
  }
  ```
  Staging repris de Compose : `tofu import random_password.secret_key_base "<SECRET_KEY_BASE du .env>"` et
  `ignore_changes = [length, special]`, comme pour `random_password.db` (sinon les sessions existantes sautent).
- Healthcheck en `bash` + `/dev/tcp` : l'image de release doit contenir bash (c'est le cas de l'image Debian
  recommandée par docker-dev).
