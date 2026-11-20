# docker-dev : Next.js + Convex

Template : `templates/Dockerfile.nextjs`. Lire aussi `node.md` (section Next.js).

## Ce qui ne s'applique pas

| Élément du bloc | Avec Convex | Pourquoi |
|---|---|---|
| Service `db` + volume `pgdata` dans `compose.yaml` | **Supprimés** | La base est hébergée par Convex |
| `DATABASE_URL` | Sans objet | Le client se connecte avec `NEXT_PUBLIC_CONVEX_URL` |
| `/health` qui teste la base (`"db":"up"`) | `"db":"none"`, toujours 200 si Next.js répond | Une panne de Convex n'est pas réparable en redémarrant notre conteneur : la faire passer « unhealthy » provoquerait des redémarrages inutiles. La disponibilité de Convex se surveille à part (bloc monitoring, sonde blackbox) |
| `depends_on: db` | Supprimé | — |

Ce qui reste : l'image Next.js (standalone, non root), `.dockerignore`, un `compose.yaml` avec le seul service `app`,
`.env.example`, `/health`.

## Développement local

Deux façons, à proposer :

1. **Sans Docker pour Convex** (le plus simple) : `npx convex dev` sur le poste (déploiement de dev dans le cloud
   Convex, ou backend local avec `npx convex dev --local`) et Next.js soit sur le poste, soit dans le conteneur `app`.
2. **Backend Convex auto-hébergé** dans le compose (image `ghcr.io/get-convex/convex-backend`) : plus lourd, utile
   seulement pour travailler hors ligne. Ne pas le proposer par défaut.

## compose.yaml

```yaml
name: monapp-local
services:
  app:
    build:
      context: .
      args:
        # URL publique de Convex, figée AU BUILD dans le JavaScript du navigateur
        # (pas un secret : elle est visible dans le navigateur de chaque visiteur).
        NEXT_PUBLIC_CONVEX_URL: ${NEXT_PUBLIC_CONVEX_URL:?NEXT_PUBLIC_CONVEX_URL manquant dans .env}
    environment:
      APP_ENV: local
      APP_VERSION: dev
    ports:
      - "127.0.0.1:${APP_PORT:-3000}:3000"
    restart: unless-stopped
```

Dans le Dockerfile, étape `build`, avant `RUN npm run build` :

```dockerfile
# Valeur publique, lue par next build. Jamais de CONVEX_DEPLOY_KEY ici : une clé passée
# en ARG reste lisible dans l'historique de l'image (docker history).
ARG NEXT_PUBLIC_CONVEX_URL
ENV NEXT_PUBLIC_CONVEX_URL=${NEXT_PUBLIC_CONVEX_URL}
```

`.env.example` : `NEXT_PUBLIC_CONVEX_URL=https://exemple-factice-123.convex.cloud` et `APP_PORT=3000`.

## /health

```ts
// app/health/route.ts : Next.js répond ; la base est hébergée par Convex, surveillée à part.
export const dynamic = 'force-dynamic';
export function GET() {
  return Response.json({ status: 'ok', db: 'none', version: process.env.APP_VERSION ?? 'dev', env: process.env.APP_ENV ?? 'local' });
}
```

## Hébergement sur Vercel

Si le front est déployé sur Vercel (cas fréquent avec Convex), il n'y a **pas** d'image à faire tourner soi-même :
le bloc ne sert qu'au développement local. Le dire, et proposer de ne l'appliquer que si l'utilisateur veut
auto-héberger.
