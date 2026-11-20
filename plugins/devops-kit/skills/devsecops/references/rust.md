# devsecops : Rust (cargo)

Partir de `templates/security.yml` ; remplacer le job `dependencies` et les règles du job `sast`. `Cargo.lock` doit
être versionné (application) : sans lui, aucun outil ne sait quelles versions sont livrées. Bibliothèque sans
`Cargo.lock` versionné : le signaler, l'audit porte alors sur les versions résolues le jour du run.

## Audit des dépendances : `cargo audit` (ou `cargo deny`)

| Outil | Quand | Exceptions |
|---|---|---|
| **`cargo audit`** (RustSec) | par défaut : un seul but, aucune config | `.cargo/audit.toml` |
| `cargo deny check advisories` | le projet a déjà un `deny.toml` (il vérifie aussi licences, doublons, sources) | `deny.toml`, section `[advisories]` |

Les deux lisent la base RustSec. Elle n'a **pas de niveaux de sévérité** fiables (beaucoup d'avis sans score CVSS) :
toute vulnérabilité fait échouer le job ; les avis « unmaintained » ou « yanked » sont des avertissements. C'est
l'équivalent du « bloque sur high/critical » des autres stacks : les avis RustSec sont peu nombreux et presque tous
sérieux.

````yaml
  dependencies:
    name: dependencies
    runs-on: ubuntu-latest
    timeout-minutes: 10
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false

      # Binaire précompilé de cargo-audit (quelques secondes au lieu de ~3 min de compilation).
      # cargo et rustup sont déjà sur ubuntu-latest.
      - uses: taiki-e/install-action@75a7c0f87bd666af3cdb75c5b9e9d03ab6044e6f # v2.90.6
        with:
          tool: cargo-audit

      # Rapport complet (JSON) pour le triage, sans bloquer...
      - name: Rapport complet (JSON)
        run: cargo audit --json > cargo-audit.json || true

      # ...puis le contrôle BLOQUANT : code 1 s'il y a une vulnérabilité dans Cargo.lock.
      # .cargo/audit.toml est lu d'office (exceptions).
      - name: Bloquer sur les vulnérabilités
        run: |
          set -o pipefail
          cargo audit | tee cargo-audit.txt

      - name: Résumé
        if: ${{ !cancelled() && hashFiles('cargo-audit.txt') != '' }}
        run: |
          { echo "### cargo audit"; echo '```'; cat cargo-audit.txt; echo '```'; } >> "$GITHUB_STEP_SUMMARY"

      - name: Rapport cargo audit
        if: ${{ !cancelled() }}
        uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2
        with:
          name: rapport-cargo-audit
          path: cargo-audit.*
          if-no-files-found: ignore
````

Variante `cargo deny` : `tool: cargo-deny` et `cargo deny check advisories` (les autres vérifications de `deny.toml`
restent dans `ci.yml` si le projet les y a déjà).

**Exceptions** :

```toml
# .cargo/audit.toml
[advisories]
# RUSTSEC-2023-0071 (rsa, canal auxiliaire) : seulement en dépendance de sqlx-mysql, non compilé ici
# (feature postgres seule) ; revu par X le 2026-11-20, à revoir le 2027-02-28.
ignore = ["RUSTSEC-2023-0071"]
```

`cargo audit` n'a pas de date d'expiration : la date de revue va dans le commentaire **et** dans le registre de
`docs/SECURITE.md`. Avec `cargo deny`, chaque entrée porte une raison : `ignore = [{ id = "RUSTSEC-…", reason = "…" }]`.

## Semgrep (job `sast`)

Remplacer les `--config` du template par `--config p/rust`. Les règles Rust sont moins nombreuses que pour
JavaScript : `clippy -D warnings` (job `lint` de `ci.yml`) reste le premier filet, Semgrep ajoute surtout les motifs
dangereux (`unsafe`, commandes construites, TLS désactivé). Exclure `target/` (`.semgrepignore`).

## Remarques

- `taiki-e/install-action` : `ci.yml` (bloc ci) l'appelle par un tag d'outil (`@cargo-llvm-cov`), qui bouge. À
  l'épinglage (procédure du SKILL.md), passer à `@<SHA> # v2.x.y` avec `with: tool: cargo-llvm-cov`.
- `dtolnay/rust-toolchain@stable` est une **branche** : l'épingler sur le SHA de sa tête
  (`git ls-remote https://github.com/dtolnay/rust-toolchain refs/heads/stable`), commentaire `# stable (AAAA-MM-JJ)`,
  et garder `toolchain: stable` dans `with:` ; Dependabot ne met pas à jour un SHA de branche : le refaire à la main.
