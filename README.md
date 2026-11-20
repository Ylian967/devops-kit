# devops-kit

Plugin [Claude Code](https://code.claude.com/docs/en/plugins) qui met en place des process DevOps dans n'importe quel
projet perso. On l'installe une fois ; ensuite, dans un projet :

- on demande « **quels process de devops-kit dois-je mettre en place ?** », ou on lance `/devops-kit:devops-plan` ;
- Claude analyse le projet (stack, base, fichiers déjà présents, remote GitHub), affiche un tableau
  *bloc | pertinent ? | pourquoi | déjà en place ? | dépendances*, demande lesquels appliquer, puis les applique dans
  l'ordre des dépendances, **un bloc par branche** (application, vérification, commit, PR si on le veut) ;
- il finit par un rapport : ce qui est fait, ce qui reste à faire à la main, les vérifications en échec.

Un seul bloc : `/devops-kit:devops-apply <bloc>` (par exemple `/devops-kit:devops-apply ci`).

> État : **phase 2**. Blocs disponibles : `git-collab`, `ci`, `docker-dev`, `cd-release`. Les blocs `iac`,
> `monitoring` et `devsecops` (phase 3) apparaissent dans le diagnostic comme « pas encore disponibles ».

## Les blocs

| Bloc | Ce qu'il met en place | Dépend de |
|---|---|---|
| `git-collab` | Ruleset sur `main` via `gh api` (PR obligatoire, squash, pas de force-push), CODEOWNERS, template de PR, hook `commit-msg` Conventional Commits, CONTRIBUTING.md | — |
| `ci` | `.github/workflows/ci.yml` : lint, format, tests, seuil de couverture, intégration contre une vraie base, build, docker-build, cache, concurrency, permissions minimales ; checks requis ajoutés au ruleset | `git-collab` |
| `docker-dev` | Dockerfile multi-stage non root, `.dockerignore`, `compose.yaml` de dev avec healthchecks, route `/health` (503 si la base ne répond pas), `.env.example` | — |
| `cd-release` | `release.yml` : image ghcr.io au SHA court, scan Trivy, staging auto puis production après approbation, smoke test et rollback auto ; `compose.prod.yaml`, `deploy/` (scripts, Nginx HTTPS), `dependabot.yml`, `docs/DEPLOIEMENT.md` ; cible runner self-hosted local ou VPS en SSH | `docker-dev` (+ `ci` conseillé) |

Stacks couvertes par chaque bloc : Node / Next.js, Next.js + Convex, Java (Maven, Gradle), Rust (cargo), Elixir (mix).

## Installation en local

Prérequis : Claude Code ≥ 2.1, `git`, `gh` authentifié (`gh auth status`), Docker (pour actionlint et les tests
d'intégration).

```bash
git clone <ce-dépôt> ~/projets/devops-kit        # ou le dossier où il est déjà

# 1. Déclarer la marketplace locale (le dossier qui contient .claude-plugin/marketplace.json)
claude plugin marketplace add ~/projets/devops-kit

# 2. Installer le plugin, pour tous les projets de l'utilisateur
claude plugin install devops-kit@devops-kit

# 3. Vérifier
claude plugin list
```

Même chose depuis une session Claude Code : `/plugin marketplace add ~/projets/devops-kit`, puis
`/plugin install devops-kit@devops-kit`.

**Après une modification du plugin** : la marketplace pointe vers un chemin local, Claude Code lit donc les fichiers
directement. Il suffit de `/reload-plugins` dans une session ouverte (ou de relancer Claude Code).

**Essayer sans installer** : `claude --plugin-dir ~/projets/devops-kit/plugins/devops-kit`.

**Valider** après modification : `claude plugin validate ~/projets/devops-kit` (marketplace) et
`claude plugin validate ~/projets/devops-kit/plugins/devops-kit` (plugin).

## Organisation du dépôt

```
.claude-plugin/marketplace.json        la marketplace (un seul plugin)
plugins/devops-kit/
  .claude-plugin/plugin.json           le manifeste du plugin
  skills/devops-plan/SKILL.md          chef d'orchestre : diagnostic, choix, application, rapport
  skills/devops-apply/SKILL.md         applique un bloc ; procédure commune à tous les blocs
  skills/<bloc>/SKILL.md               dépendances, signaux de détection, étapes, vérification, gestes manuels
  skills/<bloc>/references/            variantes par stack et explications
  skills/<bloc>/templates/             fichiers modèles commentés en français
examples/node-api/                     mini-API Node sans aucun fichier DevOps, pour tester les blocs
tests/                                 tests des scripts des templates (ex. tests/cd-release-deploy.sh, sans Docker)
```

Écarts volontaires avec la structure de départ, suivant la documentation actuelle de Claude Code :

- `devops-plan` et `devops-apply` sont des **skills** (`skills/*/SKILL.md`) et non des fichiers `commands/*.md` : la
  doc recommande les skills pour les nouveaux plugins, et une skill peut se déclencher toute seule sur une question en
  langage naturel (« quels process… ? »), ce qu'une commande ne fait pas.
- Les commandes d'un plugin portent le préfixe du plugin : `/devops-kit:devops-plan`. La forme courte `/devops-plan`
  fonctionne aussi tant qu'aucune autre commande ne porte ce nom.

## Tester un bloc sur l'exemple

```bash
cp -r examples/node-api /tmp/essai && cd /tmp/essai
git init -b main && git add . && git commit -m "chore: initialise le projet" && npm ci
claude --plugin-dir ~/projets/devops-kit/plugins/devops-kit
# puis : /devops-kit:devops-plan
```

## Inspiration

Les principes (ruleset en code, squash et titre de PR conventionnel, conventional comments, CI aux noms de jobs
stables servant de checks requis, service container avec healthcheck, seuil de couverture bloquant, moindre privilège
des workflows…) viennent de la formation
[Foreach-Academy-France/formation-cda-devops](https://github.com/Foreach-Academy-France/formation-cda-devops) (TP 1 Git
collaboratif, fil rouge TaskFlow). Ce dépôt n'en recopie aucun fichier : les templates et les instructions sont écrits
pour devops-kit et généralisés à plusieurs stacks.
