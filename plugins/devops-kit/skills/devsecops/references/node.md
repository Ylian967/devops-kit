# devsecops : Node / Next.js

Template : `templates/security.yml` (écrit pour cette stack, jobs à garder tels quels sauf ce qui suit).

## Audit des dépendances (job `dependencies`)

Le gestionnaire est donné par le lockfile. Remplacer les deux commandes du job (rapport, puis contrôle bloquant) :

| Lockfile | Rapport complet (ne bloque pas) | Contrôle bloquant |
|---|---|---|
| `package-lock.json` | `npm audit --json > npm-audit.json \|\| true` | `npm audit --audit-level=high --omit=dev` |
| `pnpm-lock.yaml` | `pnpm audit --json > npm-audit.json \|\| true` | `pnpm audit --audit-level high --prod` |
| `yarn.lock` (Berry) | `yarn npm audit --recursive --json > npm-audit.json \|\| true` | `yarn npm audit --recursive --severity high --environment production` |
| `bun.lock` | — (pas d'audit intégré fiable) | `trivy fs` (voir `java.md`, il lit aussi les lockfiles npm) |

pnpm et yarn ne sont pas sur le runner : ajouter avant les commandes les mêmes steps que le job `lint` de `ci.yml`
(`pnpm/action-setup`, `corepack enable`), épinglés par SHA. Le résumé (`jq '.metadata.vulnerabilities'`) est propre au
format npm : pour pnpm il marche aussi ; pour yarn, le retirer.

**`--omit=dev` ou pas ?** Le contrôle bloquant ne regarde que les dépendances **livrées** :

- API Node (Express, Fastify…) : les `devDependencies` (tests, lint) ne partent pas en production → `--omit=dev`.
- Front construit puis servi en statique (Vite, SPA) : le livrable est **produit** par des devDependencies (bundler,
  plugins) et ce qu'elles embarquent finit chez l'utilisateur → retirer `--omit=dev`.
- Next.js : `next`, `react` sont en `dependencies` ; garder `--omit=dev`.

Monorepo (`api/`, `front/`) : une matrice sur le dossier, comme dans `ci.yml` :

```yaml
    strategy:
      fail-fast: false              # le verdict de chaque paquet, même si l'un échoue
      matrix:
        dossier: [api, front]
    defaults:
      run:
        working-directory: ${{ matrix.dossier }}
# Le check s'appelle alors « dependencies (api) », « dependencies (front) » : ce sont ces noms dans le ruleset.
# Chemin d'artefact relatif à la RACINE : path: ${{ matrix.dossier }}/npm-audit.json, name: rapport-npm-audit-${{ matrix.dossier }}
```

**Exceptions.** `npm audit` n'a pas de liste d'exceptions. Dans l'ordre :

1. `npm audit fix` (montées compatibles), relancer les tests ;
2. dépendance transitive sans correctif amont : forcer la version corrigée dans `package.json`, puis `npm install` :
   ```json
   "overrides": { "paquet-vulnerable": "^2.3.4" }
   ```
   (pnpm : `pnpm.overrides` ; yarn : `resolutions`) ;
3. aucune version corrigée et faille non atteignable : remplacer le step bloquant par `trivy fs` (voir `java.md`), qui
   lit `package-lock.json` et accepte un `.trivyignore` avec date d'expiration ; noter la décision dans
   `docs/SECURITE.md`. pnpm a aussi `pnpm.auditConfig.ignoreGhsas`, yarn `npmAuditIgnoreAdvisories`.

## Semgrep (job `sast`)

| Projet | Règles |
|---|---|
| JavaScript (Express, Node) | `--config p/javascript --config p/nodejsscan` (le template) |
| TypeScript | ajouter `--config p/typescript` |
| React / Next.js | ajouter `--config p/react` |

Exclure ce qui n'est pas notre code avec un `.semgrepignore` à la racine (même syntaxe que `.gitignore`) : `dist/`,
`.next/`, `coverage/`, code généré. `node_modules/` est ignoré d'office.

Vérifier qu'une règle lève bien (à proposer) : un fichier jetable avec
`db.query("SELECT * FROM t WHERE id = " + req.query.id)` → Semgrep signale une injection SQL ; supprimer le fichier.

## En-têtes (proxy) et Next.js

Le template `security-headers.conf` vise une application sans script inline. **Next.js en injecte** (hydratation) :
avec la CSP du template, la page s'affiche mais rien n'est interactif (console : *Refused to execute inline script*).
Deux choix :

- **simple** : dans le proxy, `script-src 'self' 'unsafe-inline'` (et `style-src 'self' 'unsafe-inline'` si des
  styles inline sont générés). La CSP protège encore du chargement de scripts d'autres domaines, plus de l'injection
  inline : le dire dans `docs/SECURITE.md`, et la règle ZAP 10055 restera en `WARN` ;
- **strict** : CSP à nonce générée par l'application (middleware Next.js, voir la documentation Next « Content
  Security Policy »). Alors **retirer** la ligne `Content-Security-Policy` du proxy : deux en-têtes CSP s'appliquent
  tous les deux, le plus strict gagne et casse la page. Les autres en-têtes restent au proxy.

En dev (`next dev`), `'unsafe-eval'` est nécessaire : ne jamais le recopier dans la CSP du proxy.

Next.js hébergé **sans** notre proxy (Vercel, Netlify) : pas de `security-headers.conf`. Poser les mêmes en-têtes dans
`next.config.*` :

```js
// next.config.mjs : mêmes en-têtes que deploy/nginx/security-headers.conf, sur toutes les routes
const enTetes = [
  { key: 'X-Frame-Options', value: 'DENY' },                                  // anti-clickjacking
  { key: 'X-Content-Type-Options', value: 'nosniff' },                        // pas de type « deviné »
  { key: 'Referrer-Policy', value: 'strict-origin-when-cross-origin' },       // URL complète jamais envoyée aux tiers
  { key: 'Permissions-Policy', value: 'camera=(), microphone=(), geolocation=()' }, // API inutilisées coupées
];
export default {
  poweredByHeader: false,                                                     // retire X-Powered-By: Next.js
  async headers() { return [{ source: '/:path*', headers: enTetes }]; },
};
```

HSTS est alors posé par l'hébergeur (Vercel le fait d'office) : le vérifier avec `curl -sI`.

## Express sans proxy devant (dev, tests)

`app.disable('x-powered-by')` et une limite de taille de corps (`express.json({ limit: '100kb' })`) sont des
correctifs du code, hors de ce bloc : les proposer dans une PR séparée si ZAP ou Semgrep les signalent.
