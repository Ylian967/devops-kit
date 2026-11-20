# docker-dev : Rust (cargo)

Template : `templates/Dockerfile.rust` — `cargo-chef` pour le cache des dépendances, image finale **distroless**
(`cc-debian13:nonroot`) : ni shell, ni gestionnaire de paquets, utilisateur 65532.

## Adapter le Dockerfile

| Situation | Changement |
|---|---|
| Nom du binaire | `ARG APP_BIN=<nom>` (le `name` de `[[bin]]` ou du paquet dans `Cargo.toml`) |
| `rust-toolchain.toml` | Image `cargo-chef` avec la même version de Rust |
| Workspace | `--bin` ou `-p <crate>` dans `cargo build` ; `cargo chef` gère les workspaces |
| Dépend d'OpenSSL (`native-tls`) | Préférer `rustls` (pas de bibliothèque système). Sinon : `apt-get install libssl-dev pkg-config` dans `chef`, et `libssl3` à fournir au runtime (passer alors à `debian:trixie-slim` + utilisateur créé) |
| Binaire 100 % statique (musl) | Image finale `gcr.io/distroless/static-debian13:nonroot` |
| SQLx en mode hors ligne | Versionner `.sqlx/` (`cargo sqlx prepare`) et `ENV SQLX_OFFLINE=true` dans `build` : la compilation ne cherche pas de base |

Distroless n'a pas de `id` : vérifier l'utilisateur avec
`docker inspect --format '{{.Config.User}}' <image>` (attendu `65532:65532`).

## Route /health (axum)

```rust
// État partagé : le pool SQLx (Option : None si l'application n'a pas de base).
async fn health(State(pool): State<Option<PgPool>>) -> (StatusCode, Json<serde_json::Value>) {
    let version = std::env::var("APP_VERSION").unwrap_or_else(|_| "dev".into());
    let env = std::env::var("APP_ENV").unwrap_or_else(|_| "local".into());
    let db = match &pool {
        None => "none",
        // SELECT 1 borné à 2 s : une base figée donne 503 rapidement.
        Some(p) => match tokio::time::timeout(Duration::from_secs(2), sqlx::query("SELECT 1").execute(p)).await {
            Ok(Ok(_)) => "up",
            _ => "down",
        },
    };
    let code = if db == "down" { StatusCode::SERVICE_UNAVAILABLE } else { StatusCode::OK };
    let status = if db == "down" { "degraded" } else { "ok" };
    (code, Json(json!({ "status": status, "db": db, "version": version, "env": env })))
}
// Router::new().route("/health", get(health)).with_state(pool)
```

actix-web : même logique avec `web::Data<PgPool>` et `HttpResponse::ServiceUnavailable()`.

## Healthcheck sans shell : la sous-commande `healthcheck`

Distroless ne contient ni curl ni shell : le binaire se vérifie lui-même. Le template lance
`/app/server healthcheck`. À ajouter au début de `main` :

```rust
// `server healthcheck` : appelle /health en local et sort en 0 (OK) ou 1 (KO).
// Utilisé par le HEALTHCHECK du Dockerfile (pas de curl dans l'image distroless).
if std::env::args().nth(1).as_deref() == Some("healthcheck") {
    let port = std::env::var("PORT").unwrap_or_else(|_| "8080".into());
    let ok = std::net::TcpStream::connect(("127.0.0.1", port.parse::<u16>().unwrap_or(8080)))
        .and_then(|mut s| {
            use std::io::{Read, Write};
            s.set_read_timeout(Some(std::time::Duration::from_secs(2)))?;
            s.write_all(b"GET /health HTTP/1.0\r\nHost: localhost\r\n\r\n")?;
            let mut buf = [0u8; 16];
            s.read(&mut buf)?;
            Ok(buf.starts_with(b"HTTP/1.1 200") || buf.starts_with(b"HTTP/1.0 200"))
        })
        .unwrap_or(false);
    std::process::exit(if ok { 0 } else { 1 });
}
```

Si l'utilisateur ne veut pas toucher à `main` : passer l'image finale à `debian:trixie-slim` avec `curl`, ou retirer
le `HEALTHCHECK` du Dockerfile et le laisser au compose (moins bien : `docker run` seul n'a plus d'état de santé).

## compose.yaml

Port 8080 ; `DATABASE_URL` au format `postgres://…` (lu par SQLx et Diesel). Écouter sur `0.0.0.0` dans le conteneur
(`127.0.0.1` le rendrait injoignable depuis l'extérieur du conteneur).
