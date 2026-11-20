# Contribuer à NOM_DU_PROJET

Quelques règles courtes pour que `main` reste toujours fonctionnelle et que l'historique se lise encore dans six mois.

## 1. Le flux : GitHub Flow

- `main` est toujours livrable. **Personne ne pousse directement dessus** : un ruleset GitHub le refuse
  (`GH013: Repository rule violations found`), administrateurs compris.
- Chaque changement vit sur **sa branche**, courte (quelques heures à quelques jours), partie de `main` à jour.
- Il revient dans `main` par une **Pull Request** dont les vérifications sont vertes, puis il est fusionné en **squash** :
  un commit par PR dans `main`, dont le message est le **titre de la PR**.

```
main      ──●────────────●──────────●──▶   un commit par PR
             \          ▲          ▲
feat/…        ●──●──●──┘ squash   │
fix/…                  ●──●───────┘
```

## 2. Nommer sa branche

`<type>/<sujet-court>` en minuscules, sans accent ni espace : `feat/pagination-taches`, `fix/health-503`,
`docs/contributing`, `chore/devops-ci`.

## 3. Messages de commit : Conventional Commits

```
<type>(<portée facultative>): <description à l'impératif, sans point final, 72 caractères max>
```

| Type           | Quand                                          | Exemple                                             |
| -------------- | ---------------------------------------------- | --------------------------------------------------- |
| `feat`         | Nouvelle fonctionnalité                        | `feat(api): ajoute la pagination des tâches`        |
| `fix`          | Correction de bug                              | `fix(health): renvoie 503 quand la base est coupée` |
| `docs`         | Documentation seule                            | `docs: explique l'installation locale`              |
| `refactor`     | Réorganisation sans changement de comportement | `refactor(db): isole la création du pool`           |
| `test`         | Tests seuls                                    | `test(api): couvre le cas d'un titre vide`          |
| `ci` / `build` | Pipeline, build, dépendances                   | `ci: ajoute le job d'intégration`                   |
| `chore`        | Entretien du dépôt                             | `chore: met à jour CODEOWNERS`                      |

Un `!` après le type (`feat!:`) signale un changement cassant.

Le hook `.githooks/commit-msg` vérifie le format. **Activez-le une fois par clone** :

```bash
git config core.hooksPath .githooks
```

## 4. Avant d'ouvrir une PR

Lancez en local ce que la CI lancera :

```bash
COMMANDES_LOCALES
```

## 5. La Pull Request

1. `git push -u origin <ma-branche>`, puis `gh pr create` (ou le bouton _Compare & pull request_).
2. Titre conventionnel ; remplissez le modèle : **Ce qui change**, **Pourquoi**, **Comment vérifier**.
3. Pas prête ? Ouvrez-la en brouillon (`gh pr create --draft`), passez-la en _Ready for review_ ensuite.

## 6. La revue : _conventional comments_

Chaque commentaire commence par un label qui annonce son intention :

| Label                        | Sens                                   |
| ---------------------------- | -------------------------------------- |
| `praise:`                    | Ce qui est réussi                      |
| `issue (blocking):`          | À corriger avant la fusion             |
| `suggestion (non-blocking):` | Proposition, l'auteur décide           |
| `question:`                  | Demande d'explication, pas un reproche |
| `nitpick:`                   | Détail, jamais bloquant                |

L'auteur répond à chaque conversation puis la marque _Resolve conversation_ (le ruleset l'exige). Toute nouvelle
modification annule les approbations précédentes : on approuve ce qui sera fusionné.

## 7. Fusionner, puis nettoyer

_Squash and merge_ (vérifiez que le titre proposé est conventionnel). La branche distante est supprimée
automatiquement. En local :

```bash
git switch main && git pull
git branch -D <ma-branche>   # -D : après un squash, Git ne voit pas la branche comme fusionnée
```

## 8. En cas de conflit

Résolvez en local, sur **votre** branche :

```bash
git switch main && git pull && git switch <ma-branche>
git merge main
# éditez, retirez les marqueurs <<<<<<< ======= >>>>>>>
git diff --check             # ne doit rien afficher
git add <fichiers> && git commit --no-edit && git push
```

Deux intentions différentes sur la même ligne (conflit _sémantique_) : on en parle avec l'autre auteur avant de choisir,
et la décision est écrite dans la PR.
