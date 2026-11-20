# docker-dev : Node / Next.js

Templates : `templates/Dockerfile.node` (API), `templates/Dockerfile.nextjs` (Next.js).

## Adapter le Dockerfile (API)

| Situation | Changement |
|---|---|
| Pas de script `build` (JavaScript lancé tel quel) | Supprimer l'étape `build` ; dans `runtime` : `COPY src ./src` au lieu de `COPY --from=build /app/dist ./dist` ; `CMD ["node", "src/server.js"]` |
| TypeScript | Garder `build` ; vérifier le dossier de sortie (`outDir` de `tsconfig.json`) et le point d'entrée compilé |
| `.nvmrc` / `engines` | Même version majeure dans `NODE_IMAGE` (prendre la dernière corrective `node:<maj>.<min>.<patch>-alpine<ver>`) |
| pnpm | `RUN corepack enable` puis `COPY package.json pnpm-lock.yaml ./` et `pnpm install --frozen-lockfile --prod` ; cache : `--mount=type=cache,target=/root/.local/share/pnpm/store` |
| Dépendance native (`bcrypt`, `sharp`) | Alpine (musl) peut poser problème : passer à `node:<ver>-bookworm-slim` et garder l'utilisateur `node` |
| Démarrage par `npm start` | Remplacer par la commande `node …` que lance le script : npm ne relaie pas SIGTERM de façon fiable |

L'image officielle contient `npm` : inutile à l'exécution, et Trivy y trouve régulièrement des vulnérabilités.
Option pour le bloc `cd-release` (image plus petite, moins d'alertes) — dans l'étape `runtime`, avant `USER` :

```dockerfile
# npm et npx ne servent pas à l'exécution (on lance `node`) : moins de logiciel, moins de failles.
RUN rm -rf /usr/local/lib/node_modules/npm /usr/local/bin/npm /usr/local/bin/npx
```

## Route /health (node:http, Express, Fastify)

Contrat : `200 {"status":"ok","db":"up","version","env"}`, `503 {"status":"degraded","db":"down",…}`, `"db":"none"`
sans base. Le `ping` a un **délai court** : une base qui ne répond plus doit donner 503 en 2 s, pas bloquer le
healthcheck jusqu'à son timeout.

```js
// src/health.js : état de l'application pour les healthchecks, le smoke test et la supervision.
// `pool` = le pool pg (ou null si l'application n'a pas de base).
export async function health(pool) {
  const base = { version: process.env.APP_VERSION ?? 'dev', env: process.env.APP_ENV ?? 'local' };
  if (!pool) return { code: 200, body: { status: 'ok', db: 'none', ...base } };
  try {
    // SELECT 1 : la base répond-elle vraiment ? Promise.race borne l'attente à 2 s.
    await Promise.race([
      pool.query('SELECT 1'),
      new Promise((_, reject) => setTimeout(() => reject(new Error('timeout')), 2000)),
    ]);
    return { code: 200, body: { status: 'ok', db: 'up', ...base } };
  } catch {
    // 503 : le conteneur passe « unhealthy », le smoke test échoue, l'alerte se déclenche.
    return { code: 503, body: { status: 'degraded', db: 'down', ...base } };
  }
}
```

Branchement :

```js
// Express
app.get('/health', async (_req, res) => { const h = await health(pool); res.status(h.code).json(h.body); });
// Fastify
app.get('/health', async (_req, reply) => { const h = await health(pool); return reply.code(h.code).send(h.body); });
```

Test (`node --test`, Vitest ou Jest) : un faux pool dont `query` réussit → 200 `db: up` ; dont `query` rejette → 503
`db: down`. Pas besoin d'une vraie base.

ORM : Prisma `await prisma.$queryRaw\`SELECT 1\``, Drizzle `await db.execute(sql\`SELECT 1\`)`, Mongoose
`await mongoose.connection.db.admin().ping()`.

## Next.js

- `next.config.*` doit contenir `output: 'standalone'` : le build produit `.next/standalone/server.js` avec le strict
  nécessaire de `node_modules`. Sans cette option, le Dockerfile échoue au `COPY --from=build /app/.next/standalone`.
- Pas de dossier `public/` : supprimer la ligne `COPY --from=build /app/public ./public`.
- `/health` en App Router — fichier `app/health/route.ts` :

  ```ts
  // Route dynamique : jamais mise en cache ni générée au build (sinon elle renverrait l'état du build).
  export const dynamic = 'force-dynamic';
  export async function GET() {
    const h = await health(pool);            // même fonction que ci-dessus (ou pool = null sans base)
    return Response.json(h.body, { status: h.code });
  }
  ```
  Avec un `basePath`, l'URL devient `<basePath>/health` : la reporter dans les healthchecks et le smoke test.
- Variables `NEXT_PUBLIC_*` : lues **au build** et figées dans le JavaScript envoyé au navigateur. Une image se
  construit une fois et sert staging et production : préférer lire ces valeurs côté serveur au démarrage, sinon passer
  la valeur commune en `ARG` dans l'étape `build` (jamais un secret).
- Middleware d'authentification : laisser passer `/health` (sinon le healthcheck reçoit une redirection vers la
  connexion).

## compose.yaml

Port 3000. Autre base : MySQL `mysql:8.4` (healthcheck `mysqladmin ping -h 127.0.0.1`, volume `/var/lib/mysql`),
MongoDB `mongo:8` (healthcheck `mongosh --quiet --eval 'db.adminCommand("ping").ok'`, volume `/data/db`).

Développement avec rechargement à chaud (option, à proposer) : un service `app` avec
`develop: watch: [{ action: sync, path: ./src, target: /app/src }]` et `docker compose watch` — l'image reste celle de
production, seuls les fichiers sont synchronisés.

## Exemple

`examples/node-api` du dépôt devops-kit : API `node:http` sans étape de build, `/health` déjà conforme
(`src/app.js`), base PostgreSQL via `DATABASE_URL`.
