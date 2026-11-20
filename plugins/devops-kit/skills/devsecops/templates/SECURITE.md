# Sécurité de NOM_DU_PROJET

> Ce document dit quels contrôles de sécurité tournent, ce qui bloque une PR et pourquoi, comment poser une exception
> sans tricher, et quoi faire si un secret fuite. Il est mis à jour à chaque alerte traitée : le **registre des
> exceptions** (section 5) est la mémoire du triage.

## 1. Les contrôles

| Contrôle | Outil | Où | Quand | Ce qu'il attrape |
|---|---|---|---|---|
| Secrets, avant commit | gitleaks (hook pre-commit) | poste du développeur | `git commit` | un secret qui allait entrer dans l'historique |
| Secrets, historique | gitleaks (`security.yml`, job `secrets`) | CI | PR, push `main`, chaque lundi | un secret déjà présent dans un commit, même ancien |
| Secrets, à l'envoi | GitHub *secret scanning* + *push protection* | GitHub | `git push` | jetons de fournisseurs connus (refus du push) |
| Dépendances (SCA) | OUTIL_SCA (job `dependencies`) | CI | PR, push `main`, chaque lundi | dépendance avec une CVE connue |
| Dépendances, veille | Dependabot (alertes + PR de mise à jour) | GitHub | en continu | CVE publiées après la fusion |
| Code (SAST) | OUTIL_SAST (job `sast`) | CI | PR, push `main`, chaque lundi | injection, XSS, `eval`, désérialisation… |
| Image | Trivy (`release.yml`, job `scan`) | CD | chaque livraison | CVE dans l'image publiée |
| Application (DAST) | OWASP ZAP baseline (job `dast`) | staging | chaque lundi, à la demande, après un déploiement du staging | en-têtes manquants, cookies, fuites d'information |
| En-têtes HTTP | Nginx (`deploy/nginx/security-headers.conf`) | proxy | chaque requête | XSS, clickjacking, fuite de version |
| Workflows | actions épinglées par SHA, `permissions` minimales | `.github/workflows/` | toujours | action tierce compromise, jeton détourné |

Le passage hebdomadaire de `security.yml` rattrape ce qui change **sans** commit : une CVE publiée mardi sur une
dépendance fusionnée lundi.

## 2. Ce qui bloque, et pourquoi

| Check | Bloque la fusion ? | Pourquoi |
|---|---|---|
| `secrets` | **oui** (check requis) | un secret commité est compromis dès qu'il est poussé : aucune fusion tant qu'il n'est pas traité (section 6) |
| `dependencies` | **oui**, sur `high` et `critical` des dépendances livrées en production | ce sont les failles exploitables à distance les plus probables ; `moderate` et `low` restent visibles dans le rapport et Dependabot, sans bloquer le travail |
| `sast` | **oui**, sur tout résultat | les règles choisies sont précises ; un faux positif se neutralise sur **sa** ligne (section 5) |
| `dast` | **non** (ne tourne pas sur les PR) | il scanne le staging, donc `main` déjà déployée ; il échoue sur une règle `FAIL` de `.zap/rules.tsv` (une régression d'en-tête), les `WARN` sont à trier sans bloquer |

Pourquoi ZAP ne bloque pas sur les `WARN` : une baseline remonte beaucoup d'alertes de contexte (cache, commentaires
dans un bundle minifié…). Tout bloquer pousse à tout passer en `IGNORE`, ce qui est pire que rien. On bloque sur ce
qu'on a **corrigé** (passé en `FAIL` : test de non-régression), et on trie le reste.

Un check rouge à cause d'une CVE publiée cette semaine sur une dépendance qu'on n'a pas touchée : c'est voulu. Mettre à
jour la dépendance dans une PR à part, ou poser une exception datée (section 5).

## 3. En-têtes HTTP

Posés par le proxy (`deploy/nginx/security-headers.conf`, inclus par `deploy/nginx/app.conf`), sur toutes les
réponses (`always`) :

| En-tête | Valeur | Rôle |
|---|---|---|
| `Content-Security-Policy` | VALEUR_CSP | n'autorise que les ressources listées ; bloque la plupart des XSS |
| `Strict-Transport-Security` | `max-age=31536000` (posé par `app.conf`) | le navigateur n'utilise plus que HTTPS |
| `X-Frame-Options` | `DENY` | anti-clickjacking (doublé par `frame-ancestors 'none'`) |
| `X-Content-Type-Options` | `nosniff` | pas de JavaScript déguisé en image |
| `Referrer-Policy` | `strict-origin-when-cross-origin` | les sites tiers ne voient pas l'URL complète |
| `Permissions-Policy` | `camera=(), microphone=(), geolocation=(), payment=(), usb=()` | API du navigateur inutilisées coupées |
| `Cross-Origin-Opener-Policy` / `-Resource-Policy` | `same-origin` | isolation d'origine |

Aussi : `server_tokens off` (version de Nginx masquée), `proxy_hide_header X-Powered-By`.

Vérifier : `curl -skI https://<staging>/ | grep -iE 'content-security|strict-transport|x-frame|x-content|referrer|permissions'`
sur `/` **et** sur un fichier statique (une `location` avec son propre `add_header` perd les autres).

## 4. Workflows GitHub Actions

- Toute action est épinglée par **SHA de commit complet**, la version en commentaire (`@<40 caractères> # v7.0.1`) ;
  Dependabot les met à jour par PR. Avant de fusionner une de ces PR : lire les notes de version.
- `permissions: {}` au niveau du workflow, droits accordés job par job.
- `persist-credentials: false` sur chaque `actions/checkout` : le jeton ne reste pas dans `.git/config`.
- Aucune donnée contrôlable par un tiers (titre de PR, nom de branche, message de commit, `inputs`) n'est écrite
  avec `${{ }}` dans un `run:` : elle passe par `env:` puis `"$VARIABLE"`.
- Pas de `pull_request_target` ni de `workflow_run` (EXCEPTIONS_WORKFLOWS).

## 5. Exceptions (faux positifs et risques acceptés)

Règles communes : une exception est **étroite** (une ligne, une valeur, une CVE), **justifiée**, **datée**, et
inscrite dans le registre ci-dessous. Un vrai secret ne devient jamais une exception : il se révoque (section 6).

| Outil | Où | Comment |
|---|---|---|
| gitleaks, faux positif dans l'historique | `.gitleaksignore` | une ligne par empreinte (colonne `Fingerprint` du rapport, `commit:fichier:règle:ligne`), précédée d'un commentaire `# raison — qui — date` |
| gitleaks, valeur factice récurrente | `.gitleaks.toml` | `[[allowlists]]` sur la **valeur** (regex), jamais sur un dossier entier ni une règle |
| Semgrep | le code | `// nosemgrep: <id-de-la-règle>` sur la ligne concernée (jamais un `nosemgrep` nu), avec un commentaire qui dit pourquoi |
| Trivy (image, et `trivy fs`) | `.trivyignore` | `CVE-AAAA-NNNN exp:AAAA-MM-JJ` précédé d'un commentaire ; après la date, l'alerte revient d'elle-même |
| ZAP | `.zap/rules.tsv` | `ID<TAB>IGNORE<TAB>justification` après triage ; une alerte corrigée passe en `FAIL` |
| Audit des dépendances | voir `EXCEPTIONS_SCA` | d'abord forcer une version corrigée de la dépendance transitive ; l'exception est le dernier recours |

Avant toute exception, les quatre questions du triage : l'élément est-il atteignable en production ? la donnée vient-elle
de l'utilisateur ? quel impact (confidentialité, intégrité, disponibilité) ? décision : corriger, issue priorisée, ou
exception datée.

### Registre

| Date | Outil | Élément (règle, CVE, empreinte) | Décision | Justification | Qui | Revue le |
|---|---|---|---|---|---|---|
| | | | | | | |

## 6. En cas de fuite de secret

Un secret poussé sur GitHub est lu par des robots en quelques minutes. **La révocation passe avant le nettoyage de
Git** : réécrire l'historique ne rend pas un secret de nouveau secret (clones, forks, caches, logs l'ont déjà).

1. **Révoquer** le secret chez son fournisseur (régénérer la clé, le jeton, le mot de passe) : immédiatement.
2. **Remplacer** : nouvelle valeur au bon endroit, jamais dans Git (`.env` du serveur, secret GitHub d'environment),
   puis redéployer ; vérifier que l'application fonctionne avec la nouvelle valeur.
3. **Chercher un usage frauduleux** dans les journaux du fournisseur, entre la date du commit et la révocation.
4. **Retirer** le secret du code par un commit normal.
5. **L'historique** :
   - par défaut, on ne le réécrit pas : le secret est révoqué, donc inoffensif ; on ajoute son empreinte à
     `.gitleaksignore` avec `# révoqué le AAAA-MM-JJ` pour que le job `secrets` repasse au vert ;
   - réécriture (`git filter-repo --replace-text`) seulement si c'est nécessaire (donnée personnelle, secret
     impossible à révoquer) **et décidé explicitement** : elle impose un force-push sur `main` (contournement du
     ruleset), un nouveau clone pour chaque contributeur, et une demande au support GitHub pour purger les vues en
     cache ; les forks gardent l'ancien historique.
6. **Tracer** : une entrée dans `docs/INCIDENTS.md` (ou une issue) : quoi, quand, durée d'exposition, actions, et ce
   qui aurait dû l'empêcher (hook pre-commit absent ? fichier hors `.gitignore` ?).

## 7. Limites connues

- La baseline ZAP est **passive** : elle ne teste ni l'authentification, ni les injections, ni le contrôle d'accès.
  Elle ne remplace ni un scan actif sur le staging (`zap-full-scan.py`, cible autorisée seulement), ni une revue de
  code.
- Le SAST rate une faille construite à travers plusieurs fonctions ou fichiers ; il complète la revue, il ne la
  remplace pas.
- L'audit des dépendances ne connaît que les vulnérabilités **publiées** ; un paquet malveillant récent passe.
- LIMITES_DU_PROJET
