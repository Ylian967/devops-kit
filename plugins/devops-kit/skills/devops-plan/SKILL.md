---
name: devops-plan
description: Analyse le projet courant (stack, base de données, fichiers DevOps déjà présents, remote GitHub), affiche quels blocs devops-kit sont pertinents et déjà en place, demande lesquels appliquer puis les applique dans l'ordre des dépendances, un bloc par branche. À utiliser quand l'utilisateur demande « quels process de devops-kit dois-je mettre en place ? », « que me manque-t-il côté DevOps ? », « mets en place la CI/CD de ce projet », ou lance /devops-plan.
when_to_use: L'utilisateur veut un diagnostic DevOps de son projet ou mettre en place plusieurs process d'un coup. Pour un seul bloc nommé, préférer devops-apply.
argument-hint: "[blocs à appliquer directement, ex. git-collab ci]"
---

# devops-plan : diagnostic puis application des blocs devops-kit

Tu es le chef d'orchestre. Tu ne modifies **rien** avant que l'utilisateur ait choisi les blocs.
Tout ce que tu écris à l'utilisateur est en français.

## Catalogue des blocs

| Bloc | Rôle | Dépend de |
|---|---|---|
| `git-collab` | Ruleset sur `main`, CODEOWNERS, template de PR, hook Conventional Commits, CONTRIBUTING.md | — |
| `ci` | `.github/workflows/ci.yml` : lint, format, tests, couverture, intégration, build | `git-collab` (checks requis) |
| `docker-dev` | Dockerfiles multi-stage, compose.yaml de dev, `/health`, `.env.example` | — |
| `cd-release` | Images ghcr.io, Trivy, staging puis prod avec approbation, smoke test, rollback, proxy HTTPS, Dependabot | `docker-dev` (+ `ci` conseillé) |
| `iac` | OpenTofu pour le staging, `iac.yml` (plan en commentaire de PR), Ansible en option | `cd-release` |
| `monitoring` | `/metrics`, Prometheus, Grafana, Alertmanager, blackbox, post-mortem | `docker-dev` (+ `cd-release` conseillé) |
| `devsecops` | gitleaks, audit des dépendances, Semgrep, ZAP, durcissement des workflows | `ci` (+ `cd-release` conseillé) |

Chaque bloc disponible a sa skill : `${CLAUDE_PLUGIN_ROOT}/skills/<bloc>/SKILL.md`. Sa section
**Signaux de détection** dit s'il s'applique et ce qui est déjà en place. Lis-la pour chaque bloc disponible.

## Étape 1 : analyser le projet (lecture seule)

Lance ces commandes (en parallèle quand c'est possible) et note les résultats :

```bash
git rev-parse --show-toplevel && git status --short | head -20 && git branch --show-current
git remote get-url origin 2>/dev/null                 # remote GitHub ?
gh repo view --json nameWithOwner,visibility,defaultBranchRef,viewerPermission 2>/dev/null
gh api "repos/{owner}/{repo}/collaborators" --jq 'length' 2>/dev/null   # projet solo ou équipe ?
ls -a; ls .github .github/workflows 2>/dev/null
```

Puis identifie :

- **Stack** (une ou plusieurs, monorepo possible) : `package.json` (+ `next.config.*` → Next.js, dossier `convex/` ou
  dépendance `convex` → Next.js + Convex), `pom.xml` (Maven), `build.gradle(.kts)` (Gradle), `Cargo.toml` (Rust),
  `mix.exs` (Elixir). Note le gestionnaire de paquets (lockfile : `package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`,
  `bun.lock`) et la version visée (`.nvmrc`, `engines`, `.tool-versions`, `rust-toolchain.toml`, `<java.version>`).
- **Base de données** : dépendances (`pg`, `prisma`, `drizzle`, `mysql2`, `mongodb`, `spring-boot-starter-data-jpa`,
  `postgrex`/`ecto_sql`, `sqlx`/`diesel`), `DATABASE_URL` dans un `.env.example`, service `db` dans un compose.
  Convex = base **hébergée** : pas de conteneur de base à démarrer.
- **Fichiers DevOps présents** : `.github/`, `.githooks/`, `.husky/`, `.pre-commit-config.yaml`, `Dockerfile*`,
  `compose*.yaml`, `deploy/`, `infra/`, `monitoring/`, `CONTRIBUTING.md`.
- **Contexte GitHub** : remote présent ? dépôt public ou privé (les rulesets exigent un dépôt public ou un compte
  payant) ? l'utilisateur est-il admin (`viewerPermission` = `ADMIN`) ? seul collaborateur ?

## Étape 2 : afficher le diagnostic

Un résumé de 3 à 5 lignes (stack, base, remote, solo/équipe), puis ce tableau :

| Bloc | Pertinent ? | Pourquoi | Déjà en place ? | Dépendances |
|---|---|---|

- *Pertinent ?* : oui / non / optionnel, avec une raison concrète tirée du projet (pas une généralité).
- *Déjà en place ?* : non / partiel (dire ce qui manque) / oui (dire quels fichiers).
- Signale les **bloquants** juste sous le tableau : pas de remote GitHub, dépôt privé sur un compte gratuit, pas admin,
  arbre de travail non propre, `gh` non authentifié.

## Étape 3 : demander, puis appliquer

1. Si `$ARGUMENTS` nomme des blocs, ce sont eux qu'on applique. Sinon, demande avec l'outil AskUserQuestion
   (`multiSelect: true`) quels blocs appliquer, en proposant d'abord les blocs pertinents et pas encore en place.
   Demande dans la même question si tu dois **ouvrir une PR** pour chaque bloc via `gh` (oui / non).
2. Ajoute automatiquement les dépendances manquantes, en le disant (« `ci` dépend de `git-collab`, je l'ajoute »).
   Une dépendance déjà en place ne s'ajoute pas.
3. Trie les blocs dans l'ordre des dépendances (git-collab → ci → docker-dev → cd-release → iac / monitoring / devsecops).
4. Pour chaque bloc, dans l'ordre, suis **exactement** la procédure de
   `${CLAUDE_PLUGIN_ROOT}/skills/devops-apply/SKILL.md` (branche, application, vérification, commit, PR).
   Un bloc qui échoue n'arrête pas les autres, sauf s'ils en dépendent : ceux-là sont marqués *non appliqués*.

## Étape 4 : rapport final

Termine toujours par ce rapport, même si tout n'a pas marché :

```markdown
## Rapport devops-kit

### Fait
| Bloc | Branche | Commit | PR | Vérifications |
|---|---|---|

### À faire à la main
- [ ] … (secrets, approbateurs, runner, activation du hook dans les autres clones, etc. : reprendre la section
      « Gestes manuels » de chaque bloc appliqué, sans doublon)

### Vérifications en échec
- … (commande lancée, sortie utile, piste de correction) — ou « aucune »
```
