# monitoring : Node / Next.js

Bibliothèque : [`prom-client`](https://github.com/siimon/prom-client) (`npm install prom-client`). Templates :
`templates/metrics/node-http.js` (→ `src/metrics.js`) et son test `templates/metrics/node-http.test.js`
(→ `tests/unit/metrics.test.js`, adapter le chemin d'import).

Le module crée **son propre registre** à chaque appel de `createMetrics()` : chaque test monte une application neuve
sans hériter des compteurs du précédent (ni de l'erreur *A metric with the provided name has already been
registered*). Il expose `track(req, res)` (à appeler au début de chaque requête) et `handle(req, res)` (réponse de
`GET /metrics`).

## Règles communes à tous les frameworks

- `/metrics` est servie **avant** `track` et avant le logger de requêtes : les collectes de Prometheus (toutes les
  15 s) ne doivent gonfler ni les compteurs ni les logs.
- `route` = le **motif** (`/tasks/:id`), jamais l'URL réelle ; ce qui ne correspond à rien est compté `unmatched`.
- Le label s'appelle `status` (pas `status_code`) : les règles d'alerte et le dashboard en dépendent.
- Les tranches de l'histogramme (`BUCKETS`) encadrent le seuil de l'alerte de latence (0,5 s) : changer l'un, revoir
  l'autre.

## node:http (sans framework)

La liste `routes` donne les motifs connus ; le module les compare à l'URL.

```js
// src/app.js (extrait)
import { createMetrics } from './metrics.js';

export function createApp(db, { version = 'dev', env = 'local', metrics = createMetrics({ routes: ['/health', '/tasks'] }) } = {}) {
  return http.createServer(async (req, res) => {
    if (req.method === 'GET' && req.url.split('?')[0] === '/metrics') return metrics.handle(req, res); // pas comptée
    metrics.track(req, res); // mesure prise à la fin de la réponse
    // … routes existantes inchangées
  });
}
```

Ajouter un motif à `routes` à chaque nouvelle route : sinon elle est comptée `unmatched` (le test du projet doit le
vérifier : une requête sur la vraie application, puis `route="/tasks"` dans `/metrics`).

## Express

`routes` est inutile : Express remplit `req.route` et `req.baseUrl`, que `track` lit à la fin de la réponse.

```js
const metrics = createMetrics();
app.get('/metrics', metrics.handle);                              // AVANT le middleware de mesure
app.use((req, res, next) => { metrics.track(req, res); next(); });
// … routes
```

Routeur monté (`app.use('/api/tasks', router)` + `router.get('/')`) : le motif `/api/tasks/` est normalisé en
`/api/tasks`.

## Fastify

Fastify connaît le motif (`request.routeOptions.url`) mais ne le met pas sur la requête Node brute ; un hook le recopie
là où `track` le cherche :

```js
const metrics = createMetrics();
app.get('/metrics', async (request, reply) =>
  reply.type(metrics.register.contentType).send(await metrics.register.metrics()));
app.addHook('onRequest', async (request, reply) => {
  if (request.routeOptions.url === '/metrics') return;
  if (request.routeOptions.url) request.raw.route = { path: request.routeOptions.url }; // absent = 404 → unmatched
  metrics.track(request.raw, reply.raw);
});
```

## Next.js (sans Convex)

Ce qui change par rapport à une API Node :

| Élément | Next.js | Pourquoi |
|---|---|---|
| Middleware de mesure global | **Non** : un enrobage par route handler (`withMetrics`) | Le `middleware.ts` de Next.js tourne dans le runtime *edge* : pas de `prom-client`, et il ne voit pas le code de réponse final |
| Pages rendues côté serveur | Non mesurées par `/metrics` | Couvertes par la sonde blackbox (`/health` et URL publique) ; le RED porte sur les route handlers (`app/api/**/route.ts`) |
| Registre | Un seul, gardé sur `globalThis` | Le rechargement à chaud du dev réévalue les modules : sans ça, *metric already registered* |

```ts
// lib/metrics.ts : métriques Prometheus partagées par les route handlers.
import client from 'prom-client';

function create() {
  const register = new client.Registry();
  client.collectDefaultMetrics({ register }); // CPU, mémoire, event loop du serveur Next.js
  const labelNames = ['method', 'route', 'status'];
  return {
    register,
    requests: new client.Counter({ name: 'http_requests_total', help: 'Requêtes HTTP traitées', labelNames, registers: [register] }),
    duration: new client.Histogram({
      name: 'http_request_duration_seconds', help: 'Durée des requêtes HTTP, en secondes', labelNames,
      buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5], registers: [register],
    }),
  };
}
const g = globalThis as typeof globalThis & { __metrics?: ReturnType<typeof create> };
export const metrics = (g.__metrics ??= create());

// Enrobe un route handler : route = le motif du fichier ('/api/tasks/[id]'), écrit à la main.
export function withMetrics<C>(route: string, handler: (req: Request, ctx: C) => Promise<Response>) {
  return async (req: Request, ctx: C) => {
    const stop = metrics.duration.startTimer();
    let status = 500; // une exception non rattrapée = 500
    try {
      const res = await handler(req, ctx);
      status = res.status;
      return res;
    } finally {
      const labels = { method: req.method, route, status: String(status) };
      metrics.requests.inc(labels);
      stop(labels);
    }
  };
}
```

```ts
// app/metrics/route.ts : GET /metrics (bloqué par le proxy public, lu par Prometheus en interne)
import { metrics } from '@/lib/metrics';
export const runtime = 'nodejs';        // prom-client a besoin de Node, pas d'edge
export const dynamic = 'force-dynamic'; // jamais mis en cache au build
export async function GET() {
  return new Response(await metrics.register.metrics(), { headers: { 'content-type': metrics.register.contentType } });
}
```

```ts
// app/api/tasks/[id]/route.ts
export const GET = withMetrics('/api/tasks/[id]', async (req, { params }: { params: Promise<{ id: string }> }) => { … });
```

Test (Vitest ou `node --test`) : appeler un handler enrobé, puis `metrics.register.metrics()` contient
`route="/api/tasks/[id]"` et le bon `status`, et pas l'id réel.

## Exemple d'application

`examples/node-api` du dépôt devops-kit (node:http) : `createMetrics({ routes: ['/health', '/tasks'] })` dans
`createApp`, `/metrics` traitée avant `track`.
