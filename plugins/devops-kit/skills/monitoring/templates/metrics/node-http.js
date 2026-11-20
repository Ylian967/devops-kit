// =============================================================================
// src/metrics.js : métriques Prometheus d'une API node:http, avec prom-client
//
// Prometheus TIRE les métriques : il appelle GET /metrics toutes les 15 s, sur le
// réseau Docker de la prod (le proxy public ne doit jamais router /metrics).
// Contrat commun à tous les blocs devops-kit (les règles d'alerte et le dashboard
// en dépendent) :
//   http_requests_total{method,route,status}               compteur
//   http_request_duration_seconds{method,route,status}     histogramme
// `route` est le MOTIF ('/tasks/:id'), jamais l'URL réelle ('/tasks/42') : chaque
// valeur de label crée une série ; un robot qui essaie 100 000 URL ferait sinon
// exploser la mémoire de Prometheus (cardinalité). Ce qui ne correspond à aucun
// motif est compté sous 'unmatched'.
//
// Usage :
//   const metrics = createMetrics({ routes: ['/health', '/tasks', '/tasks/:id'] });
//   http.createServer((req, res) => {
//     if (req.method === 'GET' && req.url.split('?')[0] === '/metrics') return metrics.handle(req, res);
//     metrics.track(req, res); // AVANT de traiter la requête
//     ...
//   });
// Express : `routes` inutile, le motif vient de req.route (voir references/node.md) :
//   app.get('/metrics', metrics.handle);                        // déclarée AVANT track
//   app.use((req, res, next) => { metrics.track(req, res); next(); });
// =============================================================================
import client from 'prom-client';

// Tranches (buckets) de l'histogramme, en secondes : de 5 ms à 5 s. Le p95 est
// interpolé entre deux tranches : garder des tranches serrées autour du seuil
// d'alerte (0,5 s par défaut dans prometheus/rules/alertes.yml).
const BUCKETS = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5];

// '/tasks/:id' devient /^\/tasks\/[^/]+\/?$/ : chaque ':param' accepte un segment d'URL.
// Les caractères spéciaux des regex sont d'abord échappés : le « . » de '/v1.0/x'
// ne doit pas accepter n'importe quel caractère.
const toRegExp = (pattern) =>
  new RegExp(`^${pattern.replace(/[.*+?^${}()|[\]\\]/g, '\\$&').replace(/:[^/]+/g, '[^/]+')}/?$`);

// Un registre NEUF par appel (pas le registre global de prom-client) : chaque test
// crée son application sans hériter des compteurs du précédent, ni de l'erreur
// « A metric with the provided name has already been registered ».
export function createMetrics({ routes = [], collectDefaults = true } = {}) {
  const register = new client.Registry();

  // Métriques du process Node (CPU, mémoire, lag de l'event loop) : utiles au
  // diagnostic (méthode USE). Désactivables dans les tests pour aller plus vite.
  if (collectDefaults) client.collectDefaultMetrics({ register });

  const labelNames = ['method', 'route', 'status'];
  // Compteur : ne fait que monter (remis à 0 au redémarrage) ; on le lit avec rate().
  const requests = new client.Counter({
    name: 'http_requests_total', // suffixe _total : convention Prometheus des compteurs
    help: 'Requêtes HTTP traitées',
    labelNames,
    registers: [register],
  });
  // Histogramme : compte les requêtes par tranche de durée ; on en tire le p95.
  const duration = new client.Histogram({
    name: 'http_request_duration_seconds', // unité de base (secondes) dans le nom
    help: 'Durée de traitement des requêtes HTTP, en secondes',
    labelNames,
    buckets: BUCKETS,
    registers: [register],
  });

  const patterns = routes.map((pattern) => [pattern, toRegExp(pattern)]);
  // Motif de la requête, ou 'unmatched'. Si un routeur l'a déjà trouvé (Express
  // remplit req.route et req.baseUrl), on le prend tel quel : pas de liste
  // `routes` à tenir à jour. Sinon (node:http), on cherche dans `routes`, sans
  // la query string.
  const routeOf = (req) => {
    if (req.route?.path) {
      const route = (req.baseUrl ?? '') + req.route.path;
      return route.length > 1 ? route.replace(/\/$/, '') : route; // '/tasks/' (routeur monté) → '/tasks'
    }
    const path = req.url.split('?')[0];
    return patterns.find(([, re]) => re.test(path))?.[0] ?? 'unmatched';
  };

  // À appeler au début de chaque requête (sauf /metrics : les collectes de
  // Prometheus ne doivent pas gonfler les compteurs). La mesure est prise à
  // l'événement 'finish', quand le code HTTP est connu.
  function track(req, res) {
    const stop = duration.startTimer();
    res.on('finish', () => {
      const labels = { method: req.method, route: routeOf(req), status: String(res.statusCode) };
      requests.inc(labels);
      stop(labels);
    });
  }

  // Réponse de GET /metrics : format texte Prometheus, avec le bon Content-Type.
  async function handle(_req, res) {
    res.writeHead(200, { 'content-type': register.contentType });
    res.end(await register.metrics());
  }

  return { register, track, handle };
}
