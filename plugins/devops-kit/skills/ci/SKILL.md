---
name: ci
description: Bloc devops-kit « intégration continue » — écrit .github/workflows/ci.yml (GitHub Actions) adapté à la stack (Node/Next.js, Next.js + Convex, Java Maven/Gradle, Rust, Elixir) avec lint, formatage, tests unitaires, seuil de couverture bloquant, tests d'intégration contre une vraie base (service container), build et docker-build, cache, concurrency, permissions minimales et des noms de jobs stables, vérifie le fichier avec actionlint, puis ajoute ces jobs comme checks requis au ruleset de main. À utiliser quand l'utilisateur veut une CI, des tests automatiques sur les PR, un seuil de couverture, ou bloquer la fusion d'une PR rouge.
---

# Bloc ci

Objectif : chaque PR et chaque push sur `main` lancent, sur une machine neuve, les mêmes vérifications qu'en local ;
une PR rouge ne peut pas être fusionnée.

Procédure générale (branche, « rien n'est écrasé », commit, PR) : `${CLAUDE_PLUGIN_ROOT}/skills/devops-apply/SKILL.md`.

## Dépendances

- **git-collab** : le ruleset `protection-main` reçoit les checks requis de ce bloc. Sans lui, la CI tourne mais ne
  bloque rien (le dire, et proposer git-collab d'abord).
- **docker-dev** (facultatif) : le job `docker-build` n'a de sens que s'il y a un `Dockerfile`.
- Prolongé par **devsecops** (épinglage des actions par SHA, audit des dépendances) et **cd-release** (publication).

## Signaux de détection

| Signal | Lecture |
|---|---|
| Aucun `.github/workflows/*.yml` | Bloc à appliquer |
| Un workflow déclenché sur `pull_request` qui lance tests et lint | Déjà en place, au moins en partie : lister ce qui manque parmi lint, format, tests, seuil de couverture, intégration, build, `permissions`, `concurrency`, `timeout-minutes` |
| `permissions:` absent, ou `write-all` | Partiel : droits à réduire |
| `pull_request` avec `paths:` / `paths-ignore:` | Problème : les checks requis ne tournent pas sur certaines PR |
| Autre CI (`.gitlab-ci.yml`, `Jenkinsfile`, `.circleci/`) | Le signaler et demander : migrer vers GitHub Actions ou ne pas appliquer |
| Checks requis | `gh api "repos/{owner}/{repo}/rules/branches/main" --jq '.[] | select(.type=="required_status_checks") | .parameters.required_status_checks[].context'` |
| Tests présents ? | Aucun test : la CI reste utile (lint, build) mais signaler qu'un seuil de couverture n'a pas de sens tant qu'il n'y a pas de tests |

## Étapes

1. **Stack et référence** : choisir le template et lire la référence correspondante.

   | Stack | Template | Référence |
   |---|---|---|
   | Node, Next.js | `templates/ci-node.yml` | `references/node.md` |
   | Next.js + Convex | `templates/ci-node.yml` | `references/nextjs-convex.md` (+ `node.md`) |
   | Java Maven | `templates/ci-java-maven.yml` | `references/java.md` |
   | Java Gradle | `templates/ci-java-gradle.yml` | `references/java.md` |
   | Rust | `templates/ci-rust.yml` | `references/rust.md` |
   | Elixir | `templates/ci-elixir.yml` | `references/elixir.md` |

   Plusieurs stacks (monorepo) : un seul `ci.yml`, un job par paquet et par vérification, noms préfixés
   (`api-test`, `front-build`).
2. **Inventaire des commandes réelles** du projet (scripts npm, plugins Maven/Gradle, dépendances mix…). La CI ne lance
   que des commandes qui existent et passent en local. Ce qui manque (script `format:check`, seuil de couverture,
   séparation unitaires / intégration) : le proposer avec le diff, l'appliquer après accord.
3. **Lancer ces commandes en local avant d'écrire le workflow.** Mesurer la couverture actuelle ; proposer un seuil
   juste en dessous (arrondi à 5) ; l'écrire dans la config de l'outil de test (ou `COVERAGE_MIN` pour Rust). Tests
   d'intégration : les lancer contre une base jetable, la même image que le service de la CI :
   ```bash
   docker run -d --rm --name devops-kit-pg -p 55432:5432 -e POSTGRES_USER=app -e POSTGRES_PASSWORD=app \
     -e POSTGRES_DB=app postgres:17-alpine
   until docker exec devops-kit-pg pg_isready -h localhost -U app -d app >/dev/null 2>&1; do sleep 1; done
   DATABASE_URL=postgres://app:app@localhost:55432/app <commande des tests d'intégration>
   docker rm -f devops-kit-pg
   ```
4. **Écrire `.github/workflows/ci.yml`** à partir du template :
   - supprimer les jobs sans objet (`integration` sans base, `build` sans build, `docker-build` sans Dockerfile) ;
   - adapter versions, gestionnaire de paquets, chemins, nom et version de la base (MySQL, Mongo : changer l'image et
     le healthcheck du service) ;
   - garder les commentaires ; garder `permissions: contents: read`, `concurrency`, `timeout-minutes`,
     `persist-credentials: false`, et `pull_request` **sans filtre de chemins** ;
   - garder les noms de jobs `lint`, `test`, `integration`, `build`, `docker-build` (sauf monorepo).
5. **Vérifier** (section suivante), corriger jusqu'à ce qu'actionlint ne dise rien.
6. **Commit** : `ci: ajoute le pipeline d'intégration continue`, puis PR si demandé. Le corps de PR donne le seuil choisi
   et pourquoi.
7. **Checks requis** (après accord, une fois que la PR a fait tourner la CI au moins une fois et qu'elle est verte —
   `gh pr checks --watch`) : ajouter `templates/ruleset-checks.json`, réduit aux jobs réellement présents, au ruleset
   `protection-main`. `PUT` remplace toute la liste de règles : on repart de l'existant.
   ```bash
   id=$(gh api "repos/{owner}/{repo}/rulesets" --jq '.[] | select(.name=="protection-main") | .id')
   gh api "repos/{owner}/{repo}/rulesets/$id" \
     | jq --slurpfile c ruleset-checks.json \
         '{name, target, enforcement, conditions, bypass_actors,
           rules: ([.rules[] | select(.type != "required_status_checks")] + $c)}' > ruleset-v2.json
   gh api -X PUT "repos/{owner}/{repo}/rulesets/$id" --input ruleset-v2.json --jq '[.rules[].type]'
   ```
   - `integration_id: 15368` = l'application GitHub Actions : un statut du même nom publié par un autre outil ne compte pas.
   - `strict_required_status_checks_policy: false` par défaut (solo) ; `true` en équipe si l'on veut que chaque PR soit
     à jour avec `main` avant fusion (plus sûr, mais un rebase à chaque fusion d'un collègue).
   - `docker-build` n'est **pas** requis : il dépend de `lint` et `test` (déjà requis) et coûte cher ; il reste visible.
   - Matrice : les checks s'appellent `test (22)`, `test (24)` ; les mettre tels quels.

## Fichiers produits

| Fichier | Source |
|---|---|
| `.github/workflows/ci.yml` | `templates/ci-<stack>.yml` |
| Ajouts éventuels : scripts `package.json`, config de couverture, `.gitignore` (`coverage/`) | `references/<stack>.md` |
| (hors dépôt) règle `required_status_checks` du ruleset | `templates/ruleset-checks.json` |

## Vérification

```bash
# Syntaxe, expressions, scripts shell (shellcheck inclus) : ne doit rien afficher
docker run --rm -v "$PWD":/repo -w /repo rhysd/actionlint:1.7.12 -color
# Les commandes de chaque job passent en local (étape 3)
# Après push : les checks apparaissent avec les noms attendus
gh pr checks --watch
gh api "repos/{owner}/{repo}/rules/branches/main" --jq '.[] | select(.type=="required_status_checks")'
```

Preuve que le blocage marche (à proposer, pas à imposer) : une branche jetable qui casse un test → checks rouges,
*Merging is blocked* ; puis fermer la PR sans fusionner et supprimer la branche.

## Gestes manuels à laisser à l'utilisateur

- [ ] Si les checks requis n'ont pas été ajoutés : le faire après le premier run vert (commande de l'étape 7).
- [ ] Dépôt privé : surveiller le quota de minutes Actions (*Settings → Billing*) ; les dépôts publics sont gratuits.
- [ ] Projet Next.js qui a besoin de vrais secrets au build : les créer dans *Settings → Secrets and variables →
      Actions* (jamais dans `ci.yml`), ou reporter au bloc `cd-release`.
- [ ] Revoir le seuil de couverture quand la couverture monte (le remonter, jamais le baisser en douce).
