---
name: git-collab
description: Bloc devops-kit « Git collaboratif » — protège la branche main par un ruleset GitHub créé via gh api (PR obligatoire, fusion en squash, pas de force-push ni de suppression, checks requis ajoutés ensuite par le bloc ci), et ajoute CODEOWNERS, un template de PR (ce qui change / pourquoi / comment vérifier), un hook commit-msg Conventional Commits et un CONTRIBUTING.md. À utiliser quand l'utilisateur veut protéger main, imposer les PR et les revues, normaliser les messages de commit ou documenter comment contribuer, quelle que soit la stack.
---

# Bloc git-collab

Objectif : `main` ne change que par des PR relues, fusionnées en squash avec un titre Conventional Commits ; chaque
contributeur sait comment travailler (CONTRIBUTING.md) et son poste refuse les messages mal formés.

Procédure générale (branche, « rien n'est écrasé », commit, PR) : `${CLAUDE_PLUGIN_ROOT}/skills/devops-apply/SKILL.md`.

## Dépendances

- Aucune. C'est le premier bloc : `ci` ajoute ensuite ses checks requis à ce ruleset.
- La partie serveur (ruleset, réglages de fusion) exige un remote GitHub, `gh` authentifié, le rôle admin, et un dépôt
  **public** (ou un compte Pro/Team pour un dépôt privé). Sans cela, on livre les fichiers et on liste la partie
  serveur dans les gestes manuels.

## Signaux de détection

S'applique à **tout** dépôt Git. Moins prioritaire pour un dépôt jetable ou sans remote (le dire).

| Élément | Déjà en place si… | Commande |
|---|---|---|
| Ruleset | un ruleset actif cible la branche par défaut avec `pull_request` et `non_fast_forward` | `gh api "repos/{owner}/{repo}/rules/branches/<défaut>" --jq '.[].type'` |
| Ancienne protection | protection de branche « classique » | `gh api "repos/{owner}/{repo}/branches/<défaut>/protection"` (404 = aucune) |
| Réglages de fusion | squash seul, titre = titre de PR | `gh api "repos/{owner}/{repo}" --jq '{allow_squash_merge,allow_merge_commit,allow_rebase_merge,squash_merge_commit_title,delete_branch_on_merge}'` |
| CODEOWNERS | `.github/CODEOWNERS`, `CODEOWNERS` ou `docs/CODEOWNERS` | `ls` ; erreurs : `gh api "repos/{owner}/{repo}/codeowners/errors"` |
| Template de PR | `.github/pull_request_template.md` (ou dossier `PULL_REQUEST_TEMPLATE/`) | `ls` |
| Hook commit-msg | `.githooks/commit-msg`, `.husky/commit-msg`, `commitlint.config.*`, hook `commit-msg` dans `.pre-commit-config.yaml` ou `lefthook.yml` | `ls`, `grep` |
| Conventions suivies ? | les 20 derniers messages sont conventionnels | `git log --format=%s -20` |
| CONTRIBUTING.md | à la racine, dans `.github/` ou `docs/` | `ls` |

« Partiel » = au moins un élément présent : ne proposer que les manquants, et un diff pour ceux qui existent mais
diffèrent du modèle sur un point important (ex. merge commits autorisés, bypass non vide).

## Étapes

1. **Contexte** : stack (pour `references/stacks.md`), solo ou équipe
   (`gh api "repos/{owner}/{repo}/collaborators" --jq '.[].login'`), pseudo GitHub de l'utilisateur
   (`gh api user --jq .login`). En équipe, demander qui sont les propriétaires des chemins sensibles.
2. **`.github/CODEOWNERS`** depuis `templates/CODEOWNERS` : remplacer les pseudos fictifs, ajouter les chemins
   sensibles de la stack (`references/stacks.md`). En solo : un seul propriétaire, et le commentaire d'en-tête le dit.
3. **`.github/pull_request_template.md`** depuis `templates/pull_request_template.md` : adapter la ligne « Lint,
   formatage et tests » aux vraies commandes du projet.
4. **Hook** : `.githooks/commit-msg` depuis `templates/commit-msg` (garder le bit exécutable :
   `chmod +x` puis `git add --chmod=+x`). S'il existe déjà un gestionnaire de hooks, s'y brancher
   (`references/stacks.md`). Activer dans ce clone : `git config core.hooksPath .githooks`. Ajouter l'activation
   automatique de la stack si elle existe (script `prepare` npm, alias mix) — avec accord, car on touche un fichier du
   projet.
5. **`CONTRIBUTING.md`** depuis `templates/CONTRIBUTING.md` : remplacer `NOM_DU_PROJET` et `COMMANDES_LOCALES` (les
   commandes réelles du projet, voir `references/stacks.md`), retirer la section revue si le projet est solo et que
   l'utilisateur le souhaite. Un CONTRIBUTING.md existant : proposer d'**ajouter** les sections manquantes plutôt que
   de le remplacer.
6. **Commit** sur la branche du bloc : `chore: ajoute les règles de collaboration Git`.
7. **Côté GitHub** (après accord explicite, commande montrée avant), en suivant `references/ruleset.md` :
   1. copier `templates/ruleset-main.json` dans le scratchpad, l'adapter (solo : `required_approving_review_count: 0`
      et `require_code_owner_review: false`) ;
   2. si un ruleset `protection-main` existe : diff avec l'existant, puis `PUT` en conservant ses règles en plus
      (notamment un `required_status_checks` déjà présent) ; sinon `POST` ;
   3. aligner les réglages de fusion (`PATCH repos/{owner}/{repo}`).
   Pour CODEOWNERS et le template : ils ne s'appliquent qu'une fois **fusionnés dans main**, ce que la PR du bloc fera.

## Fichiers produits

| Fichier | Source |
|---|---|
| `.github/CODEOWNERS` | `templates/CODEOWNERS` |
| `.github/pull_request_template.md` | `templates/pull_request_template.md` |
| `.githooks/commit-msg` (exécutable) | `templates/commit-msg` |
| `CONTRIBUTING.md` | `templates/CONTRIBUTING.md` |
| (hors dépôt) ruleset `protection-main` + réglages de fusion | `templates/ruleset-main.json`, `references/ruleset.md` |

## Vérification

```bash
# Le hook refuse et accepte ce qu'il faut (sans créer de commit)
printf 'ajout truc\n'                       > /tmp/msg-ko && ! .githooks/commit-msg /tmp/msg-ko
printf 'feat(api): ajoute la pagination\n'  > /tmp/msg-ok && .githooks/commit-msg /tmp/msg-ok
git config core.hooksPath                   # attendu : .githooks
git ls-files -s .githooks/commit-msg        # attendu : mode 100755

# Côté GitHub (si appliqué)
gh api "repos/{owner}/{repo}/rulesets" --jq '.[] | select(.name=="protection-main") | {id, enforcement}'
gh api "repos/{owner}/{repo}/rules/branches/main" --jq '[.[].type]'   # contient pull_request, non_fast_forward, deletion
gh api "repos/{owner}/{repo}/codeowners/errors" --jq '.errors'        # [] une fois CODEOWNERS fusionné
```

Le test « push direct refusé » (`references/ruleset.md`) se propose à l'utilisateur, il ne se lance pas d'office.

## Gestes manuels à laisser à l'utilisateur

- [ ] Chaque autre clone (autre poste, coéquipier) : `git config core.hooksPath .githooks` (sauf activation automatique).
- [ ] Inviter les relecteurs comme collaborateurs avec accès en écriture, et vérifier leurs pseudos dans CODEOWNERS.
- [ ] Si la partie serveur n'a pas été appliquée : créer le ruleset et les réglages de fusion (commandes dans
      `references/ruleset.md`) ; dépôt privé sur compte gratuit → rendre public ou passer Pro.
- [ ] Dépôt public avec runner self-hosted plus tard : *Settings → Actions → General → Require approval for all
      external contributors*.
- [ ] Après le bloc `ci` : vérifier que les checks requis sont bien ajoutés au ruleset.
