# cd-release : variantes par stack

Ce qui change d'une stack à l'autre est petit : le port interne, le healthcheck dans `compose.prod.yaml`, les
variables de l'application, la commande de migration. Le reste (release.yml, deploy/, proxy) est commun.

| Stack | Port | Healthcheck `app` dans compose.prod.yaml | `MIGRATE_CMD` typique |
|---|---|---|---|
| Node (API) | 3000 | `node -e "fetch(…/health)…"` (template) | `npx prisma migrate deploy`, `npx drizzle-kit migrate`, `node src/migrate.js` |
| Next.js | 3000 | idem Node | idem si base ; sinon vide |
| Next.js + Convex | 3000 | idem Node | vide (voir plus bas) |
| Java Spring (Maven, Gradle) | 8080 | `["CMD-SHELL", "curl -fsS -o /dev/null http://127.0.0.1:8080/health"]` | vide : Flyway / Liquibase migrent au démarrage |
| Rust | 8080 | `["CMD", "/app/server", "healthcheck"]` | vide si `sqlx::migrate!` au démarrage ; sinon `/app/server migrate` |
| Elixir (Phoenix) | 4000 | `["CMD", "bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/4000 && printf 'GET /health HTTP/1.0\\r\\n\\r\\n' >&3 && head -n1 <&3 \| grep -q ' 200 '"]` | vide : `bin/migrate` est lancé par le `CMD` de l'image |

Le healthcheck du Dockerfile suffit en général ; celui du compose le **remplace** et sert à garder la même logique
quand l'image vient d'ailleurs. Si le Dockerfile du projet a déjà un `HEALTHCHECK`, on peut retirer celui du compose.

Toujours reporter le port dans trois endroits : `PORT` de `app`, le healthcheck, `proxy_pass http://app:<port>`.

## Node / Next.js

- Next.js : `NEXT_PUBLIC_*` est figé au build. Une même image pour staging et production ⇒ ces valeurs doivent être
  les mêmes pour les deux, ou lues côté serveur. Les passer à `build-push` par `build-args:` depuis des **variables**
  de dépôt (jamais un secret : elles finissent dans le JavaScript public).
- Retirer npm de l'image de production (voir `docker-dev/references/node.md`) fait souvent passer Trivy au vert.

## Next.js + Convex

| Élément | Avec Convex |
|---|---|
| Service `db`, volume `pgdata`, `backup.sh` | **Supprimés** : la base est hébergée et sauvegardée par Convex (exports : `npx convex export`) |
| `MIGRATE_CMD` | Vide ; le schéma est poussé avec les fonctions |
| Déploiement des fonctions | Un step `npx convex deploy` **dans chaque job de déploiement**, avant `deploy.sh`, avec `CONVEX_DEPLOY_KEY` en **secret d'environment** (une clé de déploiement par environnement Convex : staging et production sont deux déploiements Convex distincts) |
| `NEXT_PUBLIC_CONVEX_URL` | Diffère entre staging et production ⇒ figée au build, elle casse « une image pour deux environnements ». Deux options : construire une image par environnement (tag `<sha>-staging`, `<sha>-production`, le dire clairement : ce n'est plus *build once*), ou lire l'URL côté serveur et la passer au client au rendu |
| Hébergement sur Vercel | Le bloc ne s'applique pas (Vercel déploie depuis Git) : garder seulement `dependabot.yml` |

Step à ajouter (runner ou VPS, sur le runner GitHub dans les deux cas : `npx` n'a pas besoin du serveur) :

```yaml
      - uses: actions/setup-node@v7
        with:
          node-version: "22"
      - name: Déployer les fonctions Convex
        env:
          CONVEX_DEPLOY_KEY: ${{ secrets.CONVEX_DEPLOY_KEY }} # secret de l'environment : lisible après approbation
        run: npm ci && npx convex deploy
```
Ordre : fonctions Convex **puis** front, et des fonctions rétrocompatibles (l'ancien front tourne encore quelques
secondes avec le nouveau backend). Le rollback de `deploy.sh` ne revient pas sur les fonctions Convex.

## Java (Maven, Gradle)

- Variables : `SPRING_DATASOURCE_URL=jdbc:postgresql://db:5432/${POSTGRES_DB}`, `SPRING_DATASOURCE_USERNAME`,
  `SPRING_DATASOURCE_PASSWORD` à la place de `DATABASE_URL` dans `compose.prod.yaml`.
- `start_period: 60s` sur le healthcheck, `--wait-timeout` de `deploy.sh` à 300 si le démarrage est lent.
- Actuator exposé : bloquer aussi `/actuator` dans `deploy/nginx/app.conf`
  (`location ^~ /actuator { return 404; }`), comme `/metrics`.
- Build de l'image dans `build-push` : rien à changer, le Dockerfile compile (`-DskipTests` : les tests ont tourné en CI).

## Rust

- `DATABASE_URL` au format `postgres://` ; binaire distroless : pas de shell dans le conteneur, donc
  `MIGRATE_CMD` doit être une sous-commande du binaire (`/app/server migrate`) ou les migrations au démarrage.
- Build long : le cache `type=gha` de `build-push` garde les dépendances (`cargo chef cook`) entre deux runs.

## Elixir (Phoenix)

- Variables en plus dans `compose.prod.yaml` et `deploy/env.example` : `SECRET_KEY_BASE` (`mix phx.gen.secret`, une
  par environnement), `PHX_HOST` (le domaine), `PHX_SERVER=true`, `DATABASE_URL=ecto://…`.
- Les migrations au démarrage (`bin/migrate`) tournent à chaque redémarrage du conteneur : elles doivent être
  idempotentes (c'est le cas d'Ecto).

## Monorepo (plusieurs images)

`build-push` et `scan` en matrice sur les composants, une image `ghcr.io/<owner>/<repo>-<composant>` chacune :

```yaml
    strategy:
      fail-fast: false # garder le verdict de chaque image
      matrix:
        component: [api, front]
    # … context: ./${{ matrix.component }}
    #   tags: ${{ needs.prepare.outputs.image }}-${{ matrix.component }}:${{ needs.prepare.outputs.tag }}
```

Dans `compose.prod.yaml`, un service par composant, tous au même `${IMAGE_TAG}` ; le proxy route `/api/` vers `api`
et `/` vers `front`.
