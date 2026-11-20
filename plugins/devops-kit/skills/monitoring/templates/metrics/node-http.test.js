// =============================================================================
// tests/unit/metrics.test.js : test unitaire de /metrics (node --test)
//
// Prouve le contrat dont dépendent les alertes et le dashboard : format texte,
// noms des métriques, labels method/route/status, route = motif (jamais l'id),
// routes inconnues regroupées, 5xx comptées, /metrics non comptée.
// Un mini-serveur node:http suffit : aucune base, aucun réseau.
// Adapter le chemin d'import, et ajouter un test qui passe par la vraie
// application (createApp) pour vérifier que track() est bien branché.
// =============================================================================
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { createMetrics } from '../../src/metrics.js';

let server, base;
before(async () => {
  // collectDefaults: false : pas de métriques du process, sortie plus lisible
  const metrics = createMetrics({ routes: ['/tasks', '/tasks/:id', '/v1.0/ping'], collectDefaults: false });
  server = http
    .createServer((req, res) => {
      if (req.url === '/metrics') return metrics.handle(req, res);
      metrics.track(req, res);
      // Ce que fait Express quand une route correspond : req.baseUrl + req.route.path
      if (req.url.startsWith('/api/')) Object.assign(req, { baseUrl: '/api', route: { path: '/users/:id' } });
      const status = req.url === '/tasks/boom' ? 500 : req.url.startsWith('/tasks') ? 200 : 404;
      res.writeHead(status).end();
    })
    .listen(0); // port libre choisi par le système
  await new Promise((resolve) => server.once('listening', resolve));
  base = `http://localhost:${server.address().port}`;
});
after(() => server.close());

// Texte de /metrics (chaque appel de test refait ses requêtes avant de lire).
const scrape = async () => (await fetch(`${base}/metrics`)).text();

test('GET /metrics répond au format texte Prometheus', async () => {
  const res = await fetch(`${base}/metrics`);
  assert.equal(res.status, 200);
  assert.match(res.headers.get('content-type'), /^text\/plain/);
  const body = await res.text();
  assert.match(body, /# TYPE http_requests_total counter/);
  assert.match(body, /# TYPE http_request_duration_seconds histogram/);
});

test('route = le motif, jamais l’URL réelle', async () => {
  await fetch(`${base}/tasks/42?x=1`);
  const body = await scrape();
  assert.match(body, /http_requests_total\{method="GET",route="\/tasks\/:id",status="200"\} 1/);
  assert.match(
    body,
    /http_request_duration_seconds_bucket\{le="\+Inf",method="GET",route="\/tasks\/:id",status="200"\} 1/,
  );
  assert.doesNotMatch(body, /\/tasks\/42/);
});

test('routes inconnues regroupées sous unmatched', async () => {
  await fetch(`${base}/robot/1`);
  await fetch(`${base}/robot/2`);
  assert.match(await scrape(), /http_requests_total\{method="GET",route="unmatched",status="404"\} 2/);
});

test('un « . » du motif est un point, pas « n’importe quel caractère »', async () => {
  await fetch(`${base}/v1x0/ping`);
  assert.match(await scrape(), /http_requests_total\{method="GET",route="unmatched",status="404"\} 3/);
});

test('le motif trouvé par un routeur (Express) est pris tel quel', async () => {
  await fetch(`${base}/api/users/7`);
  assert.match(await scrape(), /route="\/api\/users\/:id",status="404"\} 1/);
});

test('les 5xx sont comptées (le E de RED)', async () => {
  await fetch(`${base}/tasks/boom`);
  assert.match(await scrape(), /route="\/tasks\/:id",status="500"\} 1/);
});

test('les collectes de /metrics ne sont pas comptées', async () => {
  await scrape();
  assert.doesNotMatch(await scrape(), /route="\/metrics"/);
});
