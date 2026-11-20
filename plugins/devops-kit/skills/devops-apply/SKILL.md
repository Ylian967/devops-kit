---
name: devops-apply
description: Applique un bloc devops-kit précis au projet courant (git-collab, ci, …) sur sa propre branche, avec vérification, commit Conventional Commits et PR optionnelle. Contient la procédure commune que devops-plan suit pour chaque bloc. À lancer avec /devops-kit:devops-apply <bloc>.
argument-hint: "<bloc> [--pr]"
disable-model-invocation: true
---

# devops-apply : appliquer un bloc

Bloc demandé : `$ARGUMENTS` (premier mot = nom du bloc ; `--pr` = ouvrir la PR sans redemander).

Si le bloc est absent ou inconnu, liste les blocs disponibles (dossiers de `${CLAUDE_PLUGIN_ROOT}/skills/` autres que
`devops-plan` et `devops-apply`) et demande lequel appliquer.

## Règles qui ne se discutent pas

- **Jamais de commit sur la branche par défaut.** Toujours une branche dédiée.
- **Rien n'est écrasé sans accord.** Si un fichier cible existe déjà : montre un diff entre l'existant et ce que tu
  proposes (`diff -u existant proposé`, ou un résumé si c'est long), puis demande : garder l'existant, remplacer, ou
  fusionner (tu proposes la fusion). Un fichier identique se saute sans rien demander.
- **Les templates sont des modèles, pas des fichiers à copier.** Adapte-les au projet (stack, chemins, noms, versions) et
  garde les commentaires en français : ils expliquent chaque ligne à l'utilisateur.
- **Aucune action irréversible ou visible de l'extérieur sans accord explicite** dans cette conversation : création ou
  modification de ruleset, changement des réglages du dépôt, push, création de PR. Annonce la commande exacte, attends
  le oui.
- **Aucun secret** écrit dans un fichier versionné.

## Procédure (identique pour chaque bloc)

1. **Lire la skill du bloc** : `${CLAUDE_PLUGIN_ROOT}/skills/<bloc>/SKILL.md`, puis la référence de la stack détectée
   dans son dossier `references/`, et les conventions communes à tous les blocs :
   `${CLAUDE_PLUGIN_ROOT}/skills/devops-apply/references/conventions.md` (noms de services, variables, `/health`,
   images, environnements, chemins).
2. **Vérifier les dépendances** listées par la skill. Une dépendance absente : propose de l'appliquer d'abord (même
   procédure), ou de continuer en sachant ce qui manquera.
3. **Partir d'un arbre propre.** `git status --porcelain` non vide : demande s'il faut mettre de côté (`git stash -u`)
   ou s'arrêter.
4. **Créer la branche** `chore/devops-<bloc>` :
   - depuis la branche par défaut à jour (`git switch <défaut> && git pull --ff-only` si un remote existe) ;
   - sauf si une dépendance appliquée dans cette même session n'est pas encore fusionnée : alors depuis la branche de
     cette dépendance (branches empilées ; la PR visera cette branche, dis-le).
   - Branche déjà existante : demande s'il faut la reprendre ou en créer une autre (`-2`).
5. **Appliquer** les étapes de la skill du bloc, fichier par fichier, avec la règle « rien n'est écrasé ».
6. **Formater** les fichiers produits avec le formateur du projet s'il couvre leur type (Prettier pour YAML/Markdown/
   JSON, etc.) : sinon le job `lint` du projet échouera sur nos propres fichiers. Puis **vérifier** avec les commandes
   de la section *Vérification* de la skill. Une vérification qui échoue : corrige si la
   cause est dans ce que tu viens d'écrire ; sinon note-la pour le rapport et continue.
7. **Committer** avec un message Conventional Commits en français, à l'impératif, un commit par bloc (ou quelques
   commits logiques), par exemple `ci: ajoute le pipeline d'intégration continue`. Si le projet a déjà un hook
   `commit-msg`, il doit passer : ne jamais utiliser `--no-verify`.
8. **PR** (si demandé, et seulement s'il y a un remote GitHub) : `git push -u origin <branche>` puis
   `gh pr create --title "<message du commit>" --body-file <fichier>`, avec un corps qui suit le template de PR du projet
   s'il existe (sinon : Ce qui change / Pourquoi / Comment vérifier), et qui liste les gestes manuels du bloc.
9. **Actions GitHub hors fichiers** décrites par la skill (ruleset, réglages du dépôt) : uniquement après accord, et
   après le push si elles en dépendent.
10. **Rapport du bloc** : fichiers créés / modifiés / laissés tels quels, vérifications (OK / KO avec la sortie utile),
    branche, commit, PR, puis la liste **Gestes manuels** de la skill, adaptée au projet. Quand devops-apply est lancé
    seul, présente-le avec le même format que le rapport final de devops-plan.
