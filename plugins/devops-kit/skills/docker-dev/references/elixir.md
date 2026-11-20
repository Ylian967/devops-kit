# docker-dev : Elixir (mix, Phoenix)

Template : `templates/Dockerfile.elixir` — `mix release` dans une image `hexpm/elixir`, exécution dans
`debian:trixie-slim` avec un utilisateur créé (uid 10001).

## Préparer le projet

- Les scripts de release : `mix phx.gen.release` crée `rel/overlays/bin/server` et `bin/migrate`, et
  `lib/<app>/release.ex` (migrations sans mix). Le template lance `bin/migrate && exec bin/server`. Sans Phoenix :
  écrire l'équivalent ou remplacer le `CMD` par `bin/<app> start`.
- `config/runtime.exs` lit l'environnement **au démarrage** : `DATABASE_URL`, `SECRET_KEY_BASE`, `PHX_HOST`, `PORT`.
  C'est ce qui permet une seule image pour staging et production.
- `ARG APP_NAME=<app>` : l'atome de `project/0` dans `mix.exs` (`app: :mon_app`).
- Versions : `.tool-versions` → même Elixir et Erlang dans l'image `hexpm/elixir:<elixir>-erlang-<otp>-debian-…`
  (les tags disponibles sont listés sur Docker Hub, `hexpm/elixir`).
- Pas d'assets (API pure) : supprimer `COPY assets assets` et `RUN mix assets.deploy`.

## Route /health

```elixir
# lib/mon_app_web/controllers/health_controller.ex : format commun devops-kit.
defmodule MonAppWeb.HealthController do
  use MonAppWeb, :controller

  def show(conn, _params) do
    base = %{version: System.get_env("APP_VERSION", "dev"), env: System.get_env("APP_ENV", "local")}
    # SELECT 1 avec un délai de 2 s : une base figée donne 503 rapidement.
    case Ecto.Adapters.SQL.query(MonApp.Repo, "SELECT 1", [], timeout: 2_000) do
      {:ok, _} -> json(conn, Map.merge(base, %{status: "ok", db: "up"}))
      {:error, _} -> conn |> put_status(503) |> json(Map.merge(base, %{status: "degraded", db: "down"}))
    end
  rescue
    # Pool épuisé ou connexion refusée : Ecto lève une exception plutôt qu'une erreur.
    _ -> conn |> put_status(503) |> json(%{status: "degraded", db: "down", version: System.get_env("APP_VERSION", "dev"), env: System.get_env("APP_ENV", "local")})
  end
end
```

Routeur : `get "/health", HealthController, :show` dans un `scope "/"` qui passe par un pipeline **sans**
authentification ni `:browser` (pas de session, pas de CSRF). Test : `ConnCase`, `get(conn, "/health")` → 200 ;
le cas 503 se teste en arrêtant le sandbox ou en isolant l'appel à la base derrière une fonction.

## Healthcheck

`debian-slim` n'a ni curl ni wget : le template ouvre une connexion TCP avec bash (`/dev/tcp`) et exige `200` sur la
ligne de statut. Alternative : installer `curl` dans l'étape `runtime` (+ quelques Mo).

## compose.yaml

Port 4000. Variables : `DATABASE_URL=ecto://app:app@db:5432/app` (Ecto accepte aussi `postgres://`),
`SECRET_KEY_BASE` (valeur factice de 64 caractères dans `.env.example`, générée par `mix phx.gen.secret` dans le vrai
`.env`), `PHX_HOST=localhost`, `PHX_SERVER=true`. `start_period` 30 s (migrations au démarrage).

Développement interactif (`iex -S mix phx.server`) : plus confortable hors conteneur, avec seulement `db` dans le
compose (décommenter `ports:` sur `127.0.0.1`).
