# Le ruleset de `main`, expliqué règle par règle

Un **ruleset** est l'ensemble de règles que GitHub applique à des branches. On l'écrit en JSON et on l'envoie avec
`gh api` : la configuration est rejouable, relisible et versionnable, au lieu de clics dans
*Settings → Rules → Rulesets*.

## Le fichier `templates/ruleset-main.json`

| Clé | Valeur | Pourquoi |
|---|---|---|
| `name` | `protection-main` | Nom affiché dans *Settings → Rules* ; sert à retrouver le ruleset (idempotence) |
| `target` | `branch` | Le ruleset vise des branches (pas des tags) |
| `enforcement` | `active` | Appliqué. `evaluate` = simple observation (offre payante), `disabled` = éteint |
| `conditions.ref_name.include` | `["~DEFAULT_BRANCH"]` | Cible la branche par défaut quel que soit son nom (`main`, `master`…) |
| `bypass_actors` | `[]` | **Personne** ne contourne, administrateurs compris : la règle vaut aussi les jours de rush |
| `deletion` | — | Interdit de supprimer `main` |
| `non_fast_forward` | — | Interdit le force-push (réécriture de l'historique partagé) |
| `pull_request` | voir ci-dessous | Tout changement passe par une PR |

Paramètres de `pull_request` :

| Paramètre | Équipe | Solo | Pourquoi |
|---|---|---|---|
| `required_approving_review_count` | `1` | `0` | On ne peut pas approuver sa propre PR : en solo, 1 bloquerait tout |
| `dismiss_stale_reviews_on_push` | `true` | `true` | Une approbation vaut pour la version relue, pas pour la suivante |
| `require_code_owner_review` | `true` | `false` | Avec CODEOWNERS, un propriétaire du fichier doit approuver |
| `require_last_push_approval` | `false` | `false` | `true` interdit à l'auteur du dernier push d'être l'approbateur (utile à 3+) |
| `required_review_thread_resolution` | `true` | `true` | Aucune conversation de revue laissée ouverte |
| `allowed_merge_methods` | `["squash"]` | `["squash"]` | Un commit par PR dans `main`, au message = titre de la PR |

> Ce qu'on perd avec le squash : le détail des commits de la branche dans `main`. Ce qu'on gagne : un historique
> linéaire, un commit = un changement relu et revertable d'un bloc, des messages garantis par la revue du titre.

## Les commandes

Toujours depuis le dossier du dépôt : `gh` remplace `{owner}` et `{repo}` automatiquement.

```bash
# 1. Prérequis : admin du dépôt, et dépôt public (ou compte Pro / Team pour un dépôt privé)
gh repo view --json visibility,viewerPermission

# 2. Un ruleset du même nom existe-t-il déjà ? (on met à jour au lieu de créer un doublon)
gh api "repos/{owner}/{repo}/rulesets" --jq '.[] | "\(.id) \(.name) \(.enforcement)"'
gh api "repos/{owner}/{repo}/rulesets/<id>"          # le détail, pour le comparer au fichier proposé

# 3a. Création
gh api -X POST "repos/{owner}/{repo}/rulesets" --input ruleset-main.json --jq '.id, .name'
# 3b. Mise à jour : PUT REMPLACE toute la liste `rules` → partir du ruleset existant, ne rien perdre
gh api -X PUT "repos/{owner}/{repo}/rulesets/<id>" --input ruleset-main.json --jq '.rules[].type'

# 4. Ce qui s'applique réellement à main (tous rulesets confondus)
gh api "repos/{owner}/{repo}/rules/branches/main" --jq '.[].type'
```

Garder le JSON hors du dépôt (dossier temporaire) ou dans `.github/rulesets/protection-main.json` si l'utilisateur
veut le versionner : GitHub ne le lit pas depuis le dépôt, c'est une copie de référence.

## Les réglages de fusion du dépôt

Le ruleset n'autorise que le squash ; on aligne les réglages du dépôt pour que le bouton propose directement le bon
message et que les branches fusionnées disparaissent :

```bash
gh api -X PATCH "repos/{owner}/{repo}" \
  -F allow_squash_merge=true -F allow_merge_commit=false -F allow_rebase_merge=false \
  -f squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=PR_BODY \
  -F delete_branch_on_merge=true --jq '{allow_squash_merge, squash_merge_commit_title, delete_branch_on_merge}'
```

## Les checks requis (ajoutés par le bloc `ci`)

Le bloc `ci` ajoute une règle `required_status_checks` à ce même ruleset, avec les **noms de jobs** de `ci.yml` et
`integration_id: 15368` (l'application *GitHub Actions* : un autre outil ne peut pas publier un faux statut vert sous
le même nom). Voir `skills/ci/SKILL.md`.

## Vérifier que la règle mord

```bash
git switch main && git commit --allow-empty -m "test: push direct sur main"
git push                                  # attendu : GH013 … Changes must be made through a pull request.
git reset --hard HEAD~1                   # annule ce commit resté local
```

À ne lancer qu'avec l'accord de l'utilisateur (c'est un push sur `main`, même s'il est refusé).

## Erreurs fréquentes

| Erreur | Cause | Correction |
|---|---|---|
| `HTTP 403 … Upgrade to GitHub Pro or make this repository public` | Dépôt privé sur compte gratuit | Rendre public, ou passer Pro ; sinon le bloc s'arrête à des fichiers sans protection serveur |
| `HTTP 404` | Pas admin, ou `gh` pas authentifié sur le bon compte | `gh auth status`, demander l'accès admin |
| `HTTP 422 Invalid request` | JSON invalide ou nom déjà pris | `jq . ruleset-main.json` ; mettre à jour l'existant (PUT) |
| Le push direct passe quand même | `enforcement` ≠ `active`, ou l'utilisateur est dans `bypass_actors` | Relire le ruleset |
| Une PR reste en *Expected — Waiting for status* | Un check requis ne correspond à aucun job | Corriger le nom dans le ruleset (`api (20)` ≠ `api`) |
