# monitoring : Elixir (Phoenix)

Phoenix émet déjà un événement `:telemetry` à la fin de chaque requête (`[:phoenix, :endpoint, :stop]`, émis par
`Plug.Telemetry` dans l'endpoint, y compris pour les 500 rendues après une exception). Il suffit de le transformer en
métriques Prometheus et de les servir sur `/metrics`.

## Deux options

| | `telemetry_metrics_prometheus_core` (proposée) | PromEx |
|---|---|---|
| Ce que c'est | Un reporter `Telemetry.Metrics` → texte Prometheus, rien d'autre | Une bibliothèque complète : plugins Phoenix, Ecto, BEAM, Oban, et ses propres dashboards Grafana |
| Noms des métriques | Ceux qu'on écrit : le contrat commun directement | Les siens (`<app>_prom_ex_phoenix_http_requests_total`, durées en **millisecondes**, label `path`) : les règles d'alerte et le dashboard du bloc ne marchent pas sans tout réécrire |
| Choisir si | Projet sans supervision, ou qui veut les alertes du bloc telles quelles | Le projet utilise déjà PromEx : alors adapter les règles et le dashboard à ses noms, le dire |

## Dépendance

```elixir
# mix.exs
{:telemetry_metrics_prometheus_core, "~> 1.2"}
```

`telemetry_metrics` est déjà là dans un projet Phoenix généré (module `MonAppWeb.Telemetry`).

## Les métriques

```elixir
# lib/mon_app_web/telemetry.ex : dans children, à côté du poller existant
{TelemetryMetricsPrometheus.Core, metrics: prometheus_metrics()}

# Contrat commun devops-kit. Les points du nom deviennent des « _ » :
# http.requests.total → http_requests_total.
defp prometheus_metrics do
  import Telemetry.Metrics
  opts = [
    event_name: [:phoenix, :endpoint, :stop],
    tags: [:method, :route, :status],
    tag_values: &http_tags/1,
    # Les collectes de Prometheus ne sont pas comptées.
    keep: fn %{conn: conn} -> conn.request_path != "/metrics" end
  ]

  [
    counter("http.requests.total", opts),
    distribution("http.request.duration.seconds",
      opts ++
        [
          measurement: :duration,
          unit: {:native, :second}, # la durée arrive en unités natives de la VM
          # mêmes tranches que les autres stacks : elles encadrent le seuil de l'alerte (0,5 s)
          reporter_options: [buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5]]
        ]
    )
  ]
end

# route = le motif du routeur ("/tasks/:id"), jamais l'URL réelle ; "unmatched" sinon.
defp http_tags(%{conn: conn}) do
  route =
    case Phoenix.Router.route_info(MonAppWeb.Router, conn.method, conn.path_info, conn.host) do
      %{route: route} -> route
      :error -> "unmatched"
    end

  %{method: conn.method, route: route, status: conn.status}
end
```

## La route `/metrics`

```elixir
# lib/mon_app_web/controllers/metrics_controller.ex
defmodule MonAppWeb.MetricsController do
  use MonAppWeb, :controller

  def index(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, TelemetryMetricsPrometheus.Core.scrape())
  end
end

# router.ex : dans un scope SANS pipeline (pas de session, pas de CSRF, pas d'authentification),
# comme /health. Le proxy public renvoie 404 sur /metrics.
scope "/", MonAppWeb do
  get "/metrics", MetricsController, :index
end
```

Variante sans route : `TelemetryMetricsPrometheus` (sans `_core`) lance son propre serveur sur le port 9568, jamais
routé par le proxy ; la cible devient `monapp-production-app-1:9568` dans `prometheus.yml`.

Port de l'application : 4000 dans les cibles de `prometheus.yml` (sondes `/health` comprises).

## Test

```elixir
# test/mon_app_web/controllers/metrics_controller_test.exs
test "GET /metrics : motif de route, pas l'URL réelle", %{conn: conn} do
  get(conn, "/tasks/42")
  body = build_conn() |> get("/metrics") |> response(200)
  assert body =~ ~s(route="/tasks/:id")
  assert body =~ "http_request_duration_seconds_bucket"
  refute body =~ "/tasks/42"
end
```

Le reporter garde son état entre les tests (processus unique) : comparer avec `=~` sur le motif, pas sur une valeur
exacte du compteur, ou lancer ce module de test avec `async: false`.
