# devsecops : Elixir (mix, Phoenix)

Partir de `templates/security.yml` ; remplacer les jobs `dependencies` et `sast`. Mêmes versions d'OTP et d'Elixir
que `ci.yml` (`OTP_VERSION`, `ELIXIR_VERSION`, ou `.tool-versions`) : les recopier dans un `env:` au niveau du
workflow.

## Audit des dépendances : `mix hex.audit` + `mix deps.audit`

| Commande | Fournie par | Ce qu'elle vérifie | Bloque |
|---|---|---|---|
| `mix hex.audit` | Hex (intégré) | paquets **retirés** par leur auteur (*retired* : faille, version cassée) | oui, code non nul s'il y en a |
| `mix deps.audit` | `mix_audit` (à ajouter) | vulnérabilités connues (base GitHub Advisory pour Hex) | oui, sur toute vulnérabilité |

`mix_audit` n'a pas de filtre de sévérité : toute vulnérabilité connue bloque. Les avis Hex sont peu nombreux ; c'est
l'équivalent du « bloque sur high/critical » des autres stacks. Ajout dans `mix.exs` (avec accord) :

```elixir
# Outils d'audit : jamais compilés dans la release (runtime: false), absents en prod.
{:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
{:sobelow, "~> 0.19", only: [:dev, :test], runtime: false},   # Phoenix seulement
```

Job à mettre à la place de `dependencies` :

````yaml
  dependencies:
    name: dependencies
    runs-on: ubuntu-latest
    timeout-minutes: 10
    permissions:
      contents: read
    env:
      MIX_ENV: test # mix_audit et sobelow sont dans les dépendances :test
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: erlef/setup-beam@54075bcc5e249e4758d363f27d099f55d843f124 # v1.24.1
        with:
          otp-version: ${{ env.OTP_VERSION }}
          elixir-version: ${{ env.ELIXIR_VERSION }}
      - run: mix deps.get

      # Paquets retirés par leur auteur : code non nul s'il y en a un dans mix.lock.
      - name: Paquets retirés (hex.audit)
        run: mix hex.audit

      # Vulnérabilités connues : code non nul s'il y en a. Sortie recopiée dans le résumé.
      - name: Vulnérabilités (deps.audit)
        run: |
          set -o pipefail
          mix deps.audit | tee deps-audit.txt
      - name: Résumé
        if: ${{ !cancelled() && hashFiles('deps-audit.txt') != '' }}
        run: |
          { echo "### mix deps.audit"; echo '```'; cat deps-audit.txt; echo '```'; } >> "$GITHUB_STEP_SUMMARY"
````

Pas de cache ici : le job est court ; ajouter celui de `ci.yml` (même clé) s'il dépasse deux minutes.

**Exceptions** : `mix deps.audit --ignore-advisory-ids GHSA-xxxx-xxxx-xxxx`, la justification et la date de revue en
commentaire au-dessus du step **et** dans le registre de `docs/SECURITE.md`. Paquet retiré : monter de version, il n'y
a pas d'exception raisonnable.

## SAST : Sobelow pour Phoenix (pas Semgrep)

Semgrep couvre mal Elixir (règles publiques quasi absentes). **Sobelow** est l'analyseur de sécurité de Phoenix :
injections SQL (`Ecto.Adapters.SQL.query` construit), XSS (`raw/1`), traversée de chemin, `binary_to_term`,
configuration (CSRF, HSTS, cookies `secure`), secrets en dur dans `config/`.

Job à mettre à la place de `sast` (mêmes steps d'installation que ci-dessus) :

````yaml
  sast:
    name: sast
    runs-on: ubuntu-latest
    timeout-minutes: 10
    permissions:
      contents: read
    env:
      MIX_ENV: test
    steps:
      # … checkout, setup-beam, mix deps.get : identiques au job dependencies
      # --exit medium : code non nul s'il y a un résultat de confiance medium ou high
      #   (les résultats « low » sont affichés sans bloquer : à lire quand même).
      # --skip : respecte les exceptions marquées dans le code (# sobelow_skip [...]).
      - name: Sobelow
        run: |
          set -o pipefail
          mix sobelow --skip --exit medium | tee sobelow.txt
      - name: Résumé
        if: ${{ !cancelled() && hashFiles('sobelow.txt') != '' }}
        run: |
          { echo "### Sobelow"; echo '```'; cat sobelow.txt; echo '```'; } >> "$GITHUB_STEP_SUMMARY"
````

Exceptions : un commentaire juste au-dessus de la fonction concernée, avec la raison,

```elixir
# Requête construite à partir d'une liste blanche de colonnes (sort_by/1), pas d'une saisie brute. Revu le 2026-11-20.
# sobelow_skip ["SQL.Query"]
def list_tasks(sort), do: ...
```

et l'entrée dans le registre. Ne pas utiliser `mix sobelow --mark-skip-all` : il fait taire tout d'un coup, sans tri.

**Projet Elixir sans Phoenix** (bibliothèque, worker) : Sobelow n'a rien à analyser. Supprimer le job `sast` (et le
retirer de la liste des checks requis), le dire dans `docs/SECURITE.md` (*Limites connues*). Credo reste un filet de
qualité, pas de sécurité.

## En-têtes et Phoenix

- `put_secure_browser_headers` (pipeline `:browser` du routeur) pose déjà `x-frame-options` (`SAMEORIGIN`),
  `x-content-type-options`, `referrer-policy` : avec le proxy, ces en-têtes partiraient en double, avec des valeurs
  différentes. Le proxy fait foi : ajouter à `security-headers.conf`
  `proxy_hide_header X-Frame-Options;`, `proxy_hide_header X-Content-Type-Options;`,
  `proxy_hide_header Referrer-Policy;` (la réponse de Phoenix perd les siens, ceux du proxy restent).
- LiveView ouvre un WebSocket sur la même origine : `connect-src 'self'` suffit (les navigateurs récents acceptent
  `wss:` de la même origine avec `'self'`).
- `force_ssl` / HSTS de Phoenix (`config/prod.exs`) : HSTS est déjà posé par le proxy (`app.conf`) ; ne pas l'activer
  aussi dans Phoenix.
