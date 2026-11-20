# ci : Node / Next.js

Template : `templates/ci-node.yml`.

## Les commandes que la CI lance

La CI lance des **scripts du `package.json`**, jamais des commandes inventées : ce qui passe en local passe en CI.

| Job | Script attendu | Si le script manque |
|---|---|---|
| `lint` | `lint`, `format:check` (et `typecheck` en TypeScript : `tsc --noEmit`) | Proposer ESLint + Prettier (config minimale ci-dessous), ou retirer le step avec accord |
| `test` | `test:coverage` (seuil compris) | Le créer à partir de `test` en ajoutant la couverture et le seuil |
| `integration` | `test:int` | Le créer si des tests ont besoin d'une base ; sinon supprimer le job |
| `build` | `build` | Supprimer le job (API lancée sans build) |

Config minimale proposée quand il n'y a rien (ESLint 9, flat config) :

```js
// eslint.config.js
import js from '@eslint/js';
import globals from 'globals';
export default [
  { ignores: ['node_modules/', 'coverage/', 'dist/', '.next/'] },   // fichiers générés : jamais analysés
  js.configs.recommended,                                            // règles recommandées par ESLint
  { languageOptions: { globals: globals.node } },                    // process, Buffer… (globals.browser côté front)
];
```

```json
"scripts": { "lint": "eslint .", "format:check": "prettier --check ." }
```

Ajouter `coverage/` (et `.next/`, `dist/`) au `.gitignore` et au `.prettierignore` s'ils n'y sont pas.

## Le seuil de couverture : dans la config du projet

Le seuil est écrit **une fois**, dans l'outil de test, pour qu'il s'applique pareil en local et en CI.

| Outil | Où | Exemple |
|---|---|---|
| `node --test` (Node ≥ 22.8) | script `test:coverage` | `node --test --experimental-test-coverage --test-coverage-lines=80 'tests/**/*.test.js'` |
| Vitest | `vitest.config.*` | `test: { coverage: { provider: 'v8', thresholds: { lines: 80 } } }` puis `vitest run --coverage` |
| Jest | `jest.config.*` | `coverageThreshold: { global: { lines: 80 } }` puis `jest --coverage` |

Choisir le seuil **juste sous la couverture actuelle** (mesurée avant, arrondie à 5 en dessous) : il empêche de
régresser sans bloquer le jour même. L'écrire et le justifier dans la PR.

Exclure de la mesure ce qui n'est pas testable unitairement (point d'entrée qui fait `listen`, fichiers générés) et le
dire en commentaire dans la config.

## Gestionnaire de paquets

Déterminé par le lockfile. Remplacer dans **chaque** job :

| Lockfile | Avant setup-node | `cache:` | Installation |
|---|---|---|---|
| `package-lock.json` | — | `npm` | `npm ci` |
| `pnpm-lock.yaml` | `- uses: pnpm/action-setup@v6` (version lue dans `packageManager`) | `pnpm` | `pnpm install --frozen-lockfile` |
| `yarn.lock` (Berry) | `- run: corepack enable` | `yarn` | `yarn install --immutable` |
| `bun.lock` | `- uses: oven-sh/setup-bun@v2` à la place de setup-node | — | `bun install --frozen-lockfile` |

Et `npm run x` devient `pnpm x`, `yarn x` ou `bun run x`.

## Version de Node

Ordre de préférence : `.nvmrc` / `.node-version` (`node-version-file:` dans setup-node, supprimer `NODE_VERSION`), sinon
la version majeure de l'image Docker du projet, sinon la LTS active. Pas de plage (`>=22`) : la CI doit tester une
version précise.

Option **matrice** (bibliothèque publiée, ou migration de version en cours) sur le job `test` :

```yaml
strategy:
  fail-fast: false             # garder le verdict de chaque version même si l'une échoue
  matrix:
    node: [22, 24]
# … node-version: ${{ matrix.node }}
```

Les checks s'appellent alors `test (22)` et `test (24)` : ce sont **ces** noms qu'il faut mettre dans le ruleset.

## Monorepo (`api/`, `front/`…)

Un job par paquet et par vérification, nommé `<paquet>-<vérif>` (`api-test`, `front-build`) ; dans chaque job :

```yaml
defaults:
  run:
    working-directory: api                     # les `run:` s'exécutent dans api/
# et dans setup-node :
    cache-dependency-path: api/package-lock.json   # relatif à la RACINE du dépôt, pas au working-directory
```

`working-directory` ne s'applique pas aux actions (`uses:`) : leurs chemins restent relatifs à la racine.

## Next.js

- `next lint` a disparu de Next 16 : lancer `eslint .` avec `eslint-config-next`.
- Le job `build` lance `next build` et garde le cache `.next/cache` (déjà dans le template).
- `next build` lit les variables `NEXT_PUBLIC_*` au moment du build. Si le build en a besoin, leur donner une valeur
  factice **non secrète** dans le job (`env: NEXT_PUBLIC_API_URL: https://example.invalid`). Un vrai secret ne va
  jamais dans `ci.yml` ; s'il est indispensable au build, c'est un sujet pour le bloc `cd-release`.
- Base de données (Prisma, Drizzle…) : le job `integration` applique les migrations avant les tests
  (`npx prisma migrate deploy`, `npx drizzle-kit migrate`).
- Avec Convex : voir `nextjs-convex.md`.

## Exemple d'application

`examples/node-api` du dépôt devops-kit : `node --test`, seuil 80 % dans `test:coverage`, `test:int` ignoré sans
`DATABASE_URL`, pas de script `build` → jobs `lint`, `test`, `integration`.
