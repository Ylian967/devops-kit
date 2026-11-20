# ci : Rust (cargo)

Template : `templates/ci-rust.yml`.

## Toolchain

`dtolnay/rust-toolchain@stable` installe la stable ; si le dépôt a un `rust-toolchain.toml`, rustup l'applique de
lui-même (garder l'action pour les `components`). Une MSRV déclarée (`rust-version` dans `Cargo.toml`) peut avoir son
job `msrv` : `dtolnay/rust-toolchain@<version>` puis `cargo check --locked` (non requis).

`Cargo.lock` doit être versionné pour une application (c'est le défaut de cargo) : `--locked` le vérifie.

## Seuil de couverture

Cargo n'a pas de fichier de configuration pour la couverture : le seuil est la variable `COVERAGE_MIN` du workflow, et
la même commande en local :

```bash
cargo install cargo-llvm-cov            # une fois
cargo llvm-cov --fail-under-lines 80    # échoue sous 80 % ; --html pour un rapport navigable
```

Écrire cette commande dans CONTRIBUTING.md pour que le seuil soit connu.

## Tests d'intégration contre une base

Convention proposée, sans dépendance supplémentaire :

```rust
#[tokio::test]
#[ignore = "base requise : DATABASE_URL"]   // ignoré par `cargo test`, lancé par `cargo test -- --ignored`
async fn insere_et_relit_une_tache() {
    let url = std::env::var("DATABASE_URL").expect("DATABASE_URL");
    // …
}
```

- **sqlx** avec les macros `query!` : la compilation vérifie les requêtes contre une base. En CI sans base, il faut le
  cache hors-ligne : `cargo sqlx prepare` en local, versionner `.sqlx/`, et `SQLX_OFFLINE=true` dans les jobs `lint`,
  `test` et `build`. Les migrations du job `integration` : `cargo sqlx migrate run` (avec `sqlx-cli`) ou
  `sqlx::migrate!()` dans le test.
- **diesel** : `diesel migration run` avant les tests (avec `diesel_cli`).
- Pas de base : supprimer le job `integration`.

## Workspace

Ajouter `--workspace` à `clippy`, `llvm-cov`, `test` et `build`.
