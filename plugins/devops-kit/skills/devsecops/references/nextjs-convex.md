# devsecops : Next.js + Convex

Lire d'abord `node.md` (audit npm, Semgrep, en-têtes Next.js) : tout s'applique. Ce qui change avec Convex :

## Ce qui ne s'applique pas, ou change

| Élément du bloc | Avec Convex | Pourquoi |
|---|---|---|
| Durcissement de la base (port non publié, mots de passe par environnement) | **Sans objet** | Pas de base dans le compose : elle est hébergée par Convex ; son accès passe par les fonctions |
| Exception gitleaks `postgres://app:app@…` (`.gitleaks.toml`) | **Supprimée** | Aucune URL de base dans le dépôt |
| ZAP (`dast`) | Sur le **front** du staging (`STAGING_URL`) | Les appels à Convex partent du navigateur vers `*.convex.cloud` : ZAP ne scanne pas Convex, qui n'est pas à nous (et n'est pas une cible autorisée) |
| Front hébergé sur Vercel (pas de cd-release) | Pas de `security-headers.conf` ; en-têtes dans `next.config.*` (`node.md`) ; `STAGING_URL` = l'URL de *preview* ou de staging Vercel | Vercel est le proxy |
| Semgrep | Analyse aussi `convex/` (TypeScript), avec `p/typescript` | Les fonctions Convex sont le backend : c'est là que se jouent l'accès aux données et l'autorisation |

## Le vrai risque : des fonctions publiques sans contrôle

Toute `query` / `mutation` / `action` exportée par `convex/` est **appelable par n'importe qui** connaissant l'URL du
déploiement (elle est dans le bundle du front). Semgrep ne connaît pas Convex : ces points se vérifient à la revue, et
se listent dans `docs/SECURITE.md` (section *Limites connues*) :

- chaque fonction publique valide ses arguments (`args: { id: v.id("tasks") }`) ;
- chaque fonction qui lit ou écrit des données d'un utilisateur vérifie l'identité
  (`const identity = await ctx.auth.getUserIdentity(); if (!identity) throw …`) **et** la propriété du document ;
- ce qui ne doit pas être appelé du navigateur est déclaré `internalQuery` / `internalMutation` / `internalAction`.

Proposer (sans l'imposer) une recherche rapide des fonctions publiques sans contrôle d'identité :

```bash
grep -rlE 'export const \w+ = (query|mutation|action)\(' convex --include='*.ts' \
  | xargs grep -L 'getUserIdentity'      # fichiers de fonctions publiques qui ne vérifient jamais l'identité
```

## Secrets

- `CONVEX_DEPLOY_KEY` (une par environnement Convex) : uniquement en secret d'**environment** GitHub (cd-release), jamais
  dans `.env.local` versionné. `.env.local` (écrit par `npx convex dev`) doit être dans `.gitignore` : le vérifier.
- `NEXT_PUBLIC_CONVEX_URL` n'est **pas** un secret (elle est dans le bundle) : ne pas la mettre dans une exception
  gitleaks, elle n'est pas détectée.
- Les règles par défaut de gitleaks ne connaissent pas les clés de déploiement Convex. Si le projet en manipule, ajouter
  une règle à `.gitleaks.toml`, puis la **tester** avec une clé révoquée (le format exact doit être vérifié sur une
  vraie clé ; celui-ci est un point de départ) :

  ```toml
  # Clé de déploiement Convex (prod:…|…, preview:…|…, dev:…|…) : donne le droit de pousser du code backend.
  [[rules]]
  id = "convex-deploy-key"
  description = "Clé de déploiement Convex"
  regex = '''\b(?:prod|preview|dev):[a-z0-9-]+\|[A-Za-z0-9+/=_-]{20,}'''
  keywords = ["prod:", "preview:", "dev:"]
  ```
- Les secrets utilisés par les fonctions (clé Stripe, API tierces) vivent dans les **variables d'environnement du
  déploiement Convex** (`npx convex env set`), pas dans GitHub ni dans le dépôt.

## CSP

Le client Convex ouvre un WebSocket vers le déploiement. Avec la CSP du template, ajouter à `connect-src` :

```
connect-src 'self' https://*.convex.cloud wss://*.convex.cloud
```

Plus strict : le nom exact du déploiement à la place du joker ; mais staging et production ont deux déploiements
Convex et partagent le même `security-headers.conf` : lister les deux noms, ou garder le joker et le dire. Auth tierce (Clerk, Auth0) :
ajouter aussi son domaine à `script-src`, `connect-src` et `frame-src` selon sa documentation.
