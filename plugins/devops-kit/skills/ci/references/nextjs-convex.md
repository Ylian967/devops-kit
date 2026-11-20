# ci : Next.js + Convex

Template : `templates/ci-node.yml`, avec les adaptations ci-dessous. Lire aussi `node.md`.

## Ce qui ne s'applique pas

| Élément du bloc | Avec Convex | Pourquoi |
|---|---|---|
| Job `integration` + service PostgreSQL | **Supprimé** | La base est hébergée par Convex : pas de conteneur de base à démarrer |
| Tests contre une vraie base | Remplacés par `convex-test` dans le job `test` | `convex-test` exécute les fonctions Convex contre une base simulée en mémoire, sans réseau |
| `DATABASE_URL` | Sans objet | Le client se connecte via `NEXT_PUBLIC_CONVEX_URL` |
| Déploiement des fonctions (`npx convex deploy`) | **Pas dans la CI** | C'est une livraison, pas une vérification : bloc `cd-release`, avec `CONVEX_DEPLOY_KEY` en secret d'environnement |

Checks requis : `lint`, `test`, `build`.

## Le job `lint`

Ajouter la vérification des types : les fonctions Convex sont typées de bout en bout, une erreur de type est souvent un
appel cassé entre le front et le back.

```yaml
- name: Types (TypeScript)
  run: npx tsc --noEmit
```

`convex/_generated/` doit être **versionné** (c'est la recommandation Convex) : la CI n'a alors besoin d'aucune
connexion à Convex pour vérifier les types. S'il est dans le `.gitignore`, le signaler : il faudrait sinon lancer
`npx convex codegen`, qui demande un déploiement et une clé.

## Le job `test` avec convex-test

```js
// vitest.config.mts
import { defineConfig } from 'vitest/config';
export default defineConfig({
  test: {
    environment: 'edge-runtime',            // les fonctions Convex tournent dans un runtime proche d'edge
    server: { deps: { inline: ['convex-test'] } },
    coverage: { provider: 'v8', include: ['convex/**', 'src/**'], exclude: ['convex/_generated/**'], thresholds: { lines: 70 } },
  },
});
```

Dépendances de dev : `vitest`, `@vitest/coverage-v8`, `convex-test`, `@edge-runtime/vm`.

## Le job `build`

`next build` instancie le client Convex : sans URL, il échoue. Donner une URL **factice** (pas un secret) :

```yaml
env:
  NEXT_PUBLIC_CONVEX_URL: https://placeholder.convex.cloud   # jamais appelée pendant le build
```
