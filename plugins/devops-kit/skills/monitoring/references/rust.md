# monitoring : Rust (axum)

Crates : [`metrics`](https://docs.rs/metrics) (les macros `counter!`, `histogram!`) et
[`metrics-exporter-prometheus`](https://docs.rs/metrics-exporter-prometheus) (le rendu au format Prometheus). On sert le
rendu sur la route `/metrics` de l'application : pas de second serveur HTTP, d'où `--no-default-features` (la
fonctionnalité par défaut `http-listener` lancerait le sien).

```bash
cargo add metrics
cargo add metrics-exporter-prometheus --no-default-features
```

Autre choix possible : la crate [`prometheus`](https://docs.rs/prometheus) (API plus proche de prom-client, registre
explicite). Elle fait aussi bien ; ne pas mélanger les deux dans un projet. Si le projet en utilise déjà une, la garder.

## Le middleware

```rust
// src/telemetry.rs : métriques Prometheus au contrat commun devops-kit.
// (Pas « metrics.rs » : un module `metrics` masquerait la crate du même nom.)
use axum::{extract::{MatchedPath, Request}, middleware::Next, response::Response};
use metrics_exporter_prometheus::{Matcher, PrometheusBuilder, PrometheusHandle};
use std::time::Instant;

// Mêmes tranches que les autres stacks : elles encadrent le seuil de l'alerte (0,5 s).
const BUCKETS: [f64; 10] = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0];

/// Installe l'exporteur (une fois, au démarrage). Sans `set_buckets_for_metric`, l'exporteur publie un
/// *summary* (quantiles calculés dans le processus) au lieu d'un histogramme : pas de `_bucket`, pas
/// d'agrégation possible entre instances, et les règles d'alerte ne marchent pas.
pub fn install() -> PrometheusHandle {
    PrometheusBuilder::new()
        .set_buckets_for_metric(Matcher::Full("http_request_duration_seconds".into()), &BUCKETS)
        .expect("tranches valides")
        .install_recorder()
        .expect("un seul exporteur par processus")
}

/// Mesure chaque requête. `MatchedPath` = le motif de la route (`/tasks/{id}`), jamais l'URL réelle.
pub async fn track(req: Request, next: Next) -> Response {
    let start = Instant::now();
    let method = req.method().to_string();
    let route = req
        .extensions()
        .get::<MatchedPath>()
        .map(|p| p.as_str().to_owned())
        .unwrap_or_else(|| "unmatched".into());
    let res = next.run(req).await;
    let status = res.status().as_u16().to_string();
    metrics::counter!("http_requests_total", "method" => method.clone(), "route" => route.clone(), "status" => status.clone())
        .increment(1);
    metrics::histogram!("http_request_duration_seconds", "method" => method, "route" => route, "status" => status)
        .record(start.elapsed().as_secs_f64());
    res
}
```

```rust
// src/main.rs (extrait)
mod telemetry; // en tête du fichier

// … dans main :
let handle = telemetry::install();
let app = Router::new()
    .route("/health", get(health))
    .route("/tasks/{id}", get(get_task))
    // layer : appliqué à chaque route déclarée AU-DESSUS (et au fallback 404, compté « unmatched »).
    // /metrics, ajoutée après, n'est pas mesurée : les collectes ne gonflent pas les compteurs.
    .layer(axum::middleware::from_fn(telemetry::track))
    .route("/metrics", get(move || std::future::ready(handle.render())));
```

`Router::layer` enrobe chaque route après le routage : `MatchedPath` y est connu. Ne pas mettre `track` sur un
`Router` imbriqué par `nest` puis sur le parent : chaque requête serait comptée deux fois.

Port : 8080 dans les cibles de `prometheus.yml` (sondes `/health` comprises).

## Test

Un test d'intégration avec `tower::ServiceExt::oneshot` (sans ouvrir de port) : `GET /tasks/42` puis `GET /metrics`
→ le texte contient `http_requests_total{method="GET",route="/tasks/{id}",status="200"} 1` et
`http_request_duration_seconds_bucket{…,le="0.5"}`, et pas `/tasks/42`. `install()` ne peut être appelée qu'une fois
par processus (recorder global) : la mettre dans un `std::sync::OnceLock` partagé par les tests du fichier.
