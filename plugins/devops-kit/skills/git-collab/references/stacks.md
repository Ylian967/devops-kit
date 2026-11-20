# git-collab : variantes par stack

Le bloc est le même pour toutes les stacks (ruleset, CODEOWNERS, template de PR, hook, CONTRIBUTING.md). Ce qui change :
**comment activer le hook automatiquement**, **les chemins sensibles** dans CODEOWNERS, et **les commandes locales**
de CONTRIBUTING.md (section 4).

Règle commune pour le hook : s'il existe déjà un gestionnaire de hooks (`.husky/`, `lefthook.yml`,
`.pre-commit-config.yaml`), **on s'y branche** au lieu de poser `.githooks/` (deux gestionnaires se marchent dessus,
car `core.hooksPath` n'a qu'une valeur). Exemples plus bas.

## Node / Next.js

- Activation automatique du hook : script `prepare` dans `package.json` (npm le lance après chaque `npm install` /
  `npm ci` en local). S'il y a déjà un `prepare`, l'enchaîner avec `&&`.

  ```json
  "scripts": { "prepare": "git config core.hooksPath .githooks || true" }
  ```

  `|| true` : en CI ou dans une image Docker sans `.git`, la commande échoue sans casser l'installation.
- Avec **husky** déjà en place : créer `.husky/commit-msg` contenant `.githooks/commit-msg "$1"` (et garder le script).
- CODEOWNERS en plus : `package.json` et le lockfile (les dépendances sont un sujet de sécurité),
  `next.config.*`, `middleware.ts` (auth, redirections).
- Commandes locales : celles des scripts existants, par exemple
  `npm ci && npm run lint && npm run format:check && npm test` (adapter à pnpm / yarn / bun selon le lockfile).

## Next.js + Convex

Tout ce qui précède, plus :

- CODEOWNERS : `/convex/` (schéma, fonctions serveur, règles d'accès) relu avec attention ;
  `convex/_generated/` est généré par `npx convex dev` : ne pas le relire ligne à ligne.
- CONTRIBUTING.md : rappeler que chaque développeur a **son propre déploiement de dev Convex** (`npx convex dev`), et que
  la base est hébergée : il n'y a pas de base locale à lancer.

## Java (Maven et Gradle)

- Pas de cycle `prepare` comme npm : l'activation reste **manuelle** (`git config core.hooksPath .githooks`), écrite en
  tête de CONTRIBUTING.md. Option Gradle si l'utilisateur la veut : une tâche qui lance la même commande, attachée à
  `build`. Ne pas ajouter de plugin Maven pour ça.
- CODEOWNERS : `pom.xml` / `build.gradle(.kts)`, `settings.gradle(.kts)`, `gradle/` (wrapper et catalogue de versions),
  `src/main/resources/application*.yml` (configuration).
- Commandes locales : `./mvnw -B verify` ou `./gradlew check` (préférer le wrapper s'il existe).

## Rust (cargo)

- Activation manuelle (pas de hook d'installation dans cargo ; éviter `cargo-husky`, peu maintenu).
- CODEOWNERS : `Cargo.toml`, `Cargo.lock`, `rust-toolchain.toml`, `build.rs`, `deny.toml` s'il existe.
- Commandes locales : `cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test`.

## Elixir (mix)

- Activation : un alias mix peut le faire à l'installation des dépendances, si l'utilisateur le veut :

  ```elixir
  # mix.exs, dans project/0 : aliases: aliases()
  defp aliases do
    # Après `mix deps.get`, active les hooks du dépôt (sans échouer hors d'un clone Git)
    ["deps.get": ["deps.get", fn _ -> System.cmd("git", ["config", "core.hooksPath", ".githooks"]) end]]
  end
  ```

  Sinon, activation manuelle comme pour Java.
- CODEOWNERS : `mix.exs`, `mix.lock`, `config/` (surtout `runtime.exs`), `priv/repo/migrations/`.
- Commandes locales : `mix format --check-formatted && mix credo --strict && mix test` (`credo` seulement s'il est
  dans les dépendances).

## Exemples avec un gestionnaire de hooks existant

```yaml
# .pre-commit-config.yaml : ajouter un hook local à l'étape commit-msg
- repo: local
  hooks:
    - id: conventional-commit
      name: Conventional Commits
      entry: .githooks/commit-msg
      language: script
      stages: [commit-msg]
# puis : pre-commit install --hook-type commit-msg
```

```yaml
# lefthook.yml
commit-msg:
  commands:
    conventional:
      run: .githooks/commit-msg {1}
```
