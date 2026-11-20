# devsecops : Java (Maven, Gradle)

Partir de `templates/security.yml` ; remplacer le job `dependencies` et les règles du job `sast`. Les jobs `secrets`
et `dast` ne changent pas.

## Audit des dépendances : Trivy en mode `fs`

**Choix de l'outil.**

| Outil | Pour | Contre |
|---|---|---|
| **Trivy** `fs` (retenu) | aucune clé d'API ; base téléchargée en quelques secondes ; même outil que le scan d'image de `release.yml` (cd-release), donc même `.trivyignore` ; lit `pom.xml` (résout les dépendances transitives) et `gradle.lockfile` | Gradle : demande le verrouillage des dépendances (ci-dessous) |
| osv-scanner | aucune clé ; base OSV | un outil de plus, sans gain ici |
| OWASP dependency-check | référence historique, plugins Maven/Gradle | sans clé d'API NVD, la première mise à jour de la base prend très longtemps et se fait limiter ; cache de base à gérer en CI |

Job à mettre à la place de `dependencies` (aucun JDK nécessaire : Trivy lit les fichiers) :

````yaml
  dependencies:
    name: dependencies
    runs-on: ubuntu-latest
    timeout-minutes: 10
    permissions:
      contents: read
    env:
      # Tag lisible + digest : le contenu de l'image est figé.
      TRIVY_IMAGE: aquasec/trivy:0.76.2@sha256:8f6bb947dbc528902e11f2f5be52f7b519f6a39d5d148f41166f2040499768fb
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false

      # 1) Rapport complet (toutes sévérités) pour le triage ; --exit-code 0 : ne bloque pas.
      #    Volume nommé trivy-cache : la base de vulnérabilités n'est téléchargée qu'une fois par job.
      - name: Rapport complet (JSON)
        run: >-
          docker run --rm -v "$PWD":/src -w /src -v trivy-cache:/root/.cache
          "$TRIVY_IMAGE" fs --scanners vuln --exit-code 0
          --format json --output trivy-deps.json .

      # 2) Contrôle BLOQUANT : code 1 s'il reste une vulnérabilité HIGH ou CRITICAL.
      #    .trivyignore (racine) est lu d'office : exceptions datées, voir docs/SECURITE.md.
      #    La sortie « table » est recopiée dans le résumé du run.
      - name: Bloquer sur high / critical
        run: |
          set -o pipefail
          docker run --rm -v "$PWD":/src -w /src -v trivy-cache:/root/.cache \
            "$TRIVY_IMAGE" fs --scanners vuln --severity HIGH,CRITICAL --exit-code 1 . \
            | tee trivy-deps.txt
      - name: Résumé
        if: ${{ !cancelled() && hashFiles('trivy-deps.txt') != '' }}
        run: |
          { echo "### Trivy (dépendances, HIGH et CRITICAL)"; echo '```'; cat trivy-deps.txt; echo '```'; } >> "$GITHUB_STEP_SUMMARY"

      - name: Rapport Trivy
        if: ${{ !cancelled() }}
        uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2
        with:
          name: rapport-trivy-deps
          path: trivy-deps.*
          if-no-files-found: ignore
````

Ne pas ajouter `--ignore-unfixed` ici (contrairement au scan d'image) : une faille sans correctif dans une bibliothèque
se traite par une décision écrite (`.trivyignore` daté), pas en silence.

**Maven** : Trivy lit `pom.xml` et va chercher les POM des dépendances sur Maven Central pour résoudre les
transitives. Dépôt Maven privé : il faut lui donner l'accès (`settings.xml`), sinon les transitives de ce dépôt
manquent ; le dire.

**Gradle** : Trivy ne lit que `gradle.lockfile`. Activer le verrouillage (dans `build.gradle.kts`) :

```kotlin
// Fige les versions résolues dans gradle.lockfile (versionné) : builds reproductibles, et audit possible.
dependencyLocking { lockAllConfigurations() }
```

puis `./gradlew dependencies --write-locks` et versionner `gradle.lockfile`. Changement d'une dépendance : relancer
`--write-locks` (le dire dans CONTRIBUTING.md). Si l'utilisateur refuse le verrouillage, Trivy ne voit rien : prendre
alors le plugin OWASP dependency-check avec une clé NVD (secret `NVD_API_KEY`), et le dire.

**Exceptions** : `.trivyignore` à la racine, une CVE par ligne avec date d'expiration :

```
# jackson-databind : appel non atteignable (pas de désérialisation polymorphe), revu par X le 2026-11-20
CVE-2025-12345 exp:2027-02-28
```

## Semgrep (job `sast`)

Remplacer les `--config` du template par `--config p/java`. Spring : les règles Spring sont incluses dans `p/java`.
Exclure `target/`, `build/` et le code généré (`.semgrepignore`).

## En-têtes et Spring

- Spring Security pose déjà `X-Content-Type-Options` et `X-Frame-Options` : avec le proxy, ils partiraient en double.
  Le proxy fait foi : ajouter `proxy_hide_header X-Frame-Options;` et `proxy_hide_header X-Content-Type-Options;` à
  `security-headers.conf` (garder le `Cache-Control` de Spring, il protège les réponses authentifiées).
- Actuator ne sort jamais par le proxy : `location ^~ /actuator { return 404; }` dans `app.conf` (cd-release,
  `references/stacks.md`) ; la santé publique est `/health`. Vérifier :
  `curl -sk -o /dev/null -w '%{http_code}\n' "$STAGING_URL/actuator/env"` → `404`.
- Port 8080 : `STAGING_URL` reste l'URL **publique** du proxy, jamais le port de l'application.
