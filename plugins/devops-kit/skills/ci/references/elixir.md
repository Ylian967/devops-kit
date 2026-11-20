# ci : Elixir (mix)

Template : `templates/ci-elixir.yml`.

## Versions

`.tool-versions` présent (asdf / mise) : dans chaque `erlef/setup-beam`, remplacer `otp-version` / `elixir-version` par

```yaml
with:
  version-file: .tool-versions
  version-type: strict          # versions exactes, pas « la plus récente compatible »
```

et retirer `OTP_VERSION` / `ELIXIR_VERSION` de la clé de cache au profit de `${{ hashFiles('.tool-versions') }}`.

## Seuil de couverture

Dans `mix.exs`, `project/0` :

```elixir
test_coverage: [summary: [threshold: 80]]   # mix test --cover échoue sous 80 %
```

## Unitaires et intégration

- **Bibliothèque ou appli sans base** : supprimer le job `integration` et le service.
- **Appli avec Ecto, tests séparables** : marquer les tests qui touchent la base `@moduletag :integration` ; le job
  `test` les exclut, le job `integration` ne lance qu'eux. Dans `test/test_helper.exs`, ne démarrer le sandbox Ecto
  que si nécessaire.
- **Phoenix + Ecto classique** (DataCase, ConnCase : presque tout passe par la base) : la séparation n'a pas de sens.
  Déplacer `services:` et `env:` dans le job `test`, lancer `mix test --cover` sans `--exclude`, supprimer le job
  `integration`. Checks requis : `lint`, `test`, `build`.

`config/test.exs` doit lire l'URL de la CI tout en gardant le défaut local :

```elixir
config :mon_app, MonApp.Repo,
  url: System.get_env("DATABASE_URL", "ecto://postgres:postgres@localhost/mon_app_test"),
  pool: Ecto.Adapters.SQL.Sandbox
```

`mix test` crée la base et joue les migrations grâce à l'alias Phoenix par défaut
(`test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]`) : le vérifier dans `mix.exs`.

## Lint

- `mix format --check-formatted` et `mix compile --warnings-as-errors` : toujours.
- `mix credo --strict` : seulement si `credo` est dans les dépendances (sinon proposer de l'ajouter, ou retirer le step).
- `mix deps.unlock --check-unused` : signale les dépendances inutilisées du `mix.lock` (ajout possible).

## Build

`mix release` suppose une config de release (défaut de Phoenix ≥ 1.6). Phoenix avec assets : `mix assets.deploy` avant.
Une bibliothèque : remplacer par `mix compile --warnings-as-errors` en `MIX_ENV=prod` ou `mix hex.build`.
