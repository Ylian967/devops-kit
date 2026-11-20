---
name: devsecops
description: Bloc devops-kit « DevSecOps » — écrit .github/workflows/security.yml (jobs secrets, dependencies, sast, dast) avec gitleaks sur tout l'historique, audit des dépendances bloquant sur high/critical selon la stack (npm/pnpm/yarn audit, Trivy fs pour Java, cargo audit, mix deps.audit), Semgrep (ou Sobelow pour Phoenix), OWASP ZAP baseline sur le staging, planifié chaque semaine, résultats en résumé de run et SARIF ; ajoute un hook pre-commit gitleaks (.pre-commit-config.yaml, compatible avec .githooks de git-collab), .gitleaks.toml, les en-têtes de sécurité du proxy Nginx (CSP, X-Frame-Options, nosniff…), et docs/SECURITE.md (ce qui bloque, exceptions, procédure en cas de fuite de secret) ; durcit les workflows existants (actions épinglées par SHA, permissions minimales, persist-credentials, injections ${{ }}, pull_request_target). À utiliser quand l'utilisateur veut scanner ses secrets ou ses dépendances, du SAST/DAST, des en-têtes de sécurité, sécuriser ses GitHub Actions, ou réagir à un secret commité.
---

# Bloc devsecops

Objectif : un secret, une dépendance vulnérable ou un motif de code dangereux bloque la PR qui l'apporte ; le staging
est scanné chaque semaine ; les workflows ne peuvent pas être détournés par une action tierce ou une PR malveillante ;
chaque exception est écrite, justifiée et datée.

Procédure générale (branche, « rien n'est écrasé », commit, PR) : `${CLAUDE_PLUGIN_ROOT}/skills/devops-apply/SKILL.md`.
Noms partagés (jobs `secrets`, `dependencies`, `sast`, `dast`, `deploy/nginx/security-headers.conf`,
`docs/SECURITE.md`) : `${CLAUDE_PLUGIN_ROOT}/skills/devops-apply/references/conventions.md`.

## Règles propres au bloc

- **Rien n'est écrasé sans diff et accord** : workflows existants, `.pre-commit-config.yaml`, config Nginx, hooks.
  Le durcissement des workflows (étape 9) modifie des fichiers d'autres blocs : diff par fichier, accord par fichier.
- **Un secret trouvé, c'est d'abord le révoquer.** On s'arrête, on montre le rapport (`--redact` : jamais la valeur
  en clair, ni dans la conversation ni dans un fichier), et on donne la procédure de `docs/SECURITE.md` (section 6).
  Un vrai secret ne va **jamais** dans `.gitleaks.toml` ni `.gitleaksignore` tant qu'il n'est pas révoqué.
  La réécriture de l'historique (`git filter-repo`, force-push) ne se fait qu'avec un accord **explicite** donné pour
  cette opération précise, après avoir expliqué ses conséquences.
- **ZAP ne vise que le staging du projet** (cible dont l'utilisateur est propriétaire). Baseline (passive) seulement ;
  un scan actif (`zap-full-scan.py`) ou un scan de la production : jamais sans accord explicite.

## Dépendances

- **ci** (obligatoire) : le ruleset `protection-main` reçoit les checks `secrets`, `dependencies`, `sast` ; ses
  workflows (actions par tag) sont épinglés par SHA ici. Sans `ci`, proposer de l'appliquer d'abord.
- **cd-release** (conseillé) : fournit le proxy Nginx (`app.conf` inclut `security-headers*.conf`), le staging que
  ZAP scanne, et `dependabot.yml` (qui met à jour les SHA épinglés). Sans lui : pas d'en-têtes au proxy (les poser
  dans l'application ou chez l'hébergeur, `references/node.md`), job `dast` en variante locale (étape 8) ou supprimé.
- **git-collab** (conseillé) : `.githooks/` + `core.hooksPath` ; le hook pre-commit gitleaks s'y range.

## Signaux de détection

| Élément | Déjà en place si… | Commande |
|---|---|---|
| Workflow de sécurité | gitleaks/trufflehog, audit, semgrep/codeql, zap dans un workflow | `grep -lnE 'gitleaks\|trufflehog\|audit\|semgrep\|codeql\|zap\|trivy fs' .github/workflows/*.y*ml` |
| CodeQL (*default setup*) | état `configured` | `gh api "repos/{owner}/{repo}/code-scanning/default-setup" --jq .state` (le garder : Semgrep le complète) |
| Hook de secrets | gitleaks dans `.pre-commit-config.yaml`, `.githooks/pre-commit`, `.husky/pre-commit`, `lefthook.yml` | `ls -a .pre-commit-config.yaml .githooks .husky lefthook.yml 2>/dev/null` |
| Config gitleaks | `.gitleaks.toml`, `.gitleaksignore` | `ls -a` |
| En-têtes du proxy | `deploy/nginx/security-headers.conf`, ou `add_header` dans la config Nginx | `grep -rn 'add_header' deploy/ 2>/dev/null` ; en ligne : `curl -skI "$STAGING_URL"` |
| Actions non épinglées | un `uses:` qui ne finit pas par un SHA de 40 caractères | `grep -rhnE '^\s*-?\s*uses:' .github \| grep -vE '@[0-9a-f]{40}( \|$)' \| grep -v 'uses: *\./'` |
| Permissions | workflow sans `permissions:` en tête, ou `write-all` | `grep -L '^permissions:' .github/workflows/*.y*ml` ; `grep -n 'write-all' .github/workflows/*` |
| Déclencheurs dangereux | `pull_request_target`, `workflow_run` | `grep -n 'pull_request_target\|workflow_run' .github/workflows/*` |
| Doc | `docs/SECURITE.md`, `SECURITY.md` | `ls docs SECURITY.md 2>/dev/null` |
| Réglages GitHub | secret scanning, push protection, alertes Dependabot, jeton en lecture seule | `gh api "repos/{owner}/{repo}" --jq .security_and_analysis` ; `gh api "repos/{owner}/{repo}/vulnerability-alerts" -i` (204 = activées, 404 = non) ; `gh api "repos/{owner}/{repo}/actions/permissions/workflow"` |

« Partiel » = un élément présent : ne proposer que les manquants, et un diff pour l'existant qui diffère sur un point
important (audit qui ne bloque pas, scan sans `fetch-depth: 0`, CSP absente…).

## Étapes

1. **Stack et référence.**

   | Stack | Audit (`dependencies`) | `sast` | Référence |
   |---|---|---|---|
   | Node, Next.js | `npm audit` / `pnpm audit` / `yarn npm audit` | Semgrep | `references/node.md` |
   | Next.js + Convex | idem | Semgrep (+ revue des fonctions Convex) | `references/nextjs-convex.md` (+ `node.md`) |
   | Java Maven / Gradle | Trivy `fs` | Semgrep `p/java` | `references/java.md` |
   | Rust | `cargo audit` (ou `cargo deny`) | Semgrep `p/rust` | `references/rust.md` |
   | Elixir / Phoenix | `mix hex.audit` + `mix deps.audit` | Sobelow | `references/elixir.md` |

   Monorepo : un job par paquet ou une matrice (`references/node.md`) ; les checks prennent alors le suffixe
   (`dependencies (api)`), à reporter tels quels dans le ruleset.
2. **Inventaire** : workflows existants, outils déjà en place (signaux), cible de cd-release (runner local ou VPS),
   URL du staging, hébergement du front (proxy à nous, ou Vercel/Netlify), dépôt public ou privé (Code scanning et
   secret scanning gratuits seulement en public).
3. **Secrets dans l'historique, avant tout le reste** (sinon le job `secrets` est rouge dès la première PR) :
   ```bash
   docker run --rm -v "$PWD":/repo zricethezav/gitleaks:v8.30.1 git --redact --verbose /repo   # tout l'historique
   docker run --rm -v "$PWD":/repo zricethezav/gitleaks:v8.30.1 dir --redact /repo             # fichiers actuels, non commités compris
   ```
   Vérifier « N commits scanned » (0 = mauvais dossier). Chaque résultat se trie avec l'utilisateur :
   - **vrai secret** (même vieux, même « de test » chez un vrai fournisseur) : règle « révoquer d'abord » ci-dessus ;
     une fois révoqué, son empreinte (`Fingerprint`) va dans `.gitleaksignore` avec `# révoqué le AAAA-MM-JJ` ;
   - **faux positif** : empreinte dans `.gitleaksignore` (cas isolé) ou exception de **valeur** dans `.gitleaks.toml`
     (valeur factice récurrente), une ligne de justification chacune.
4. **Lancer l'audit des dépendances et le SAST en local** avec les commandes de la référence (Semgrep en conteneur :
   `docker run --rm -v "$PWD":/src -w /src semgrep/semgrep:1.186.0 semgrep scan --config <règles> --metrics=off --error`).
   Un `high`/`critical` ou un résultat Semgrep existant fera échouer la PR du bloc. Le montrer, puis, au choix de
   l'utilisateur : le corriger dans un commit séparé de la même branche (`fix(deps): …`), poser une exception datée,
   ou laisser le check rouge en connaissance de cause (et ne pas encore le rendre requis).
5. **`.github/workflows/security.yml`** depuis `templates/security.yml` + la référence :
   - garder `permissions: {}` et les permissions par job, `persist-credentials: false`, `fetch-depth: 0` (secrets),
     `timeout-minutes`, `concurrency`, `pull_request` sans filtre de chemins, les noms de jobs ;
   - vérifier que les SHA sont toujours les derniers (procédure de l'étape 9) et les mettre à jour ensemble ;
   - dépôt privé sans GitHub Advanced Security : retirer `security-events: write` et le step « Envoyer dans Code
     scanning » (les rapports restent en artefacts et dans le résumé du run).
6. **gitleaks et pre-commit** :
   - `.gitleaks.toml` depuis `templates/gitleaks.toml` : garder `useDefault`, adapter l'exception de l'URL de base aux
     identifiants réels du `compose.yaml` et de `ci.yml` (ou la supprimer s'il n'y a pas de base) ;
   - `.pre-commit-config.yaml` depuis `templates/pre-commit-config.yaml` (fichier existant : **fusionner** les dépôts
     de hooks, ne pas remplacer) ;
   - activation, selon ce qui gère les hooks :

     | Situation | Faire |
     |---|---|
     | `.githooks/` + `core.hooksPath` (git-collab) | `.githooks/pre-commit` depuis `templates/githooks-pre-commit` (`chmod +x`, `git add --chmod=+x`) ; `pre-commit install` refuserait de s'installer |
     | husky | `.husky/pre-commit` qui appelle `pre-commit run` (ou `.githooks/pre-commit`) |
     | lefthook | `pre-commit: commands: secrets: run: pre-commit run` dans `lefthook.yml` |
     | rien | `pre-commit install` (cas 2 du template) |

   - lancer `pre-commit run --all-files` une première fois (télécharge et compile les hooks, ~1 min).
7. **En-têtes du proxy** (si cd-release est en place) : `deploy/nginx/security-headers.conf` depuis
   `templates/nginx/security-headers.conf`.
   - Vérifier que `deploy/nginx/app.conf` contient `include /etc/nginx/snippets/security-headers*.conf;` dans le
     `server` 443 et que `compose.prod.yaml` monte `deploy/nginx` sur `/etc/nginx/snippets` ; sinon proposer
     l'ajout (diff).
   - Ne pas y mettre `Strict-Transport-Security` : `app.conf` le pose.
   - Régler la CSP selon la stack (`references/<stack>.md`) ; une `location` d'`app.conf` avec son propre
     `add_header` : y ré-inclure le fichier (commentaire d'en-tête du template).
   - Projet sans proxy à nous : en-têtes dans l'application ou chez l'hébergeur (`references/node.md`).
8. **ZAP** : `.zap/rules.tsv` depuis `templates/zap-rules.tsv` (séparateur **tabulation**, à garder) et la variable
   de dépôt `STAGING_URL` (étape 12). Selon la cible :
   - **VPS** (staging public) : le job tel quel (`ubuntu-latest`).
   - **Runner local** (staging sur la machine de l'utilisateur, injoignable depuis GitHub) : `runs-on: [self-hosted,
     deploy]`, `STAGING_URL` = `https://localhost:<HTTPS_PORT du staging>`. Le runner tourne en conteneur et pilote
     le Docker de l'hôte : `-v "$PWD/zap:…"` monterait un dossier qui n'existe pas sur l'hôte. Utiliser un dossier
     visible au même chemin des deux côtés (sous `DEPLOY_ROOT`, monté tel quel par le runner), par exemple
     `wrk="$DEPLOY_ROOT_HOTE/zap-wrk"` écrit en dur dans le step, puis `cp -r "$wrk"/. zap/` avant l'envoi des rapports.
   - **Sans staging** (pas de cd-release) : variante locale, déclenchée aussi sur les PR — remplacer le step
     « Vérifier que le staging répond » par `docker compose up -d --build --wait --wait-timeout 180`, fixer
     `DAST_URL: http://localhost:<port>`, retirer la condition sur `vars.STAGING_URL` du `if:` (ou tout le `if:`),
     ajouter `docker compose down -v` en `if: always()`. ZAP voit alors l'application **sans** proxy : passer en
     `WARN` les règles d'en-têtes posés par le proxy (10035, 10036, 10038…). Ou supprimer le job, et le dire.
   - **Après chaque déploiement du staging** (option, touche `release.yml`, diff + accord) : un job à la fin de la
     livraison qui relance `security.yml` (le jeton peut déclencher un `workflow_dispatch`) :
     ```yaml
       scan-staging:
         name: scan-staging
         needs: deploy-staging
         runs-on: ubuntu-latest
         timeout-minutes: 2
         permissions:
           actions: write # déclencher security.yml, rien d'autre
         steps:
           - name: Lancer security.yml (dont le scan ZAP du staging)
             env:
               GH_TOKEN: ${{ github.token }}
             run: gh workflow run security.yml --repo "$GITHUB_REPOSITORY" --ref main
     ```
9. **Durcir les workflows existants** (`ci.yml`, `release.yml`, `iac.yml`, et ceux du projet). Un commit à part,
   un diff par fichier.
   1. **Épingler chaque action par SHA de commit**, la version exacte en commentaire. Pour chaque `uses:
      <owner>/<repo>[/chemin]@<ref>` dont la ref n'est pas un SHA de 40 caractères (les actions locales `./…` ne
      s'épinglent pas) :
      ```bash
      r=actions/checkout     # owner/repo, sans le /chemin (github/codeql-action/upload-sarif -> github/codeql-action)
      tag=$(gh api "repos/$r/releases/latest" --jq .tag_name)
      git ls-remote "https://github.com/$r" "refs/tags/$tag^{}" "refs/tags/$tag"
      # Deux lignes : prendre celle en ^{} (le commit pointé par un tag annoté).
      # Une seule ligne : c'est déjà le commit.
      ```
      → `uses: actions/checkout@<sha> # v7.0.1` (le commentaire doit être le tag exact : Dependabot le met à jour
      avec le SHA).
      - `releases/latest` absent (404) ou hors sujet (codeql-action renvoie `codeql-bundle-…`) : lister les tags,
        `git ls-remote --tags "https://github.com/$r" | grep -v '\^{}' | awk '{print $2}' | sort -V | tail -5`.
      - **Rester sur la majeure utilisée** (`@v4` → dernier `v4.x.y`) ; une nouvelle majeure (entrées renommées,
        runtime Node changé) se propose à part, notes de version lues.
      - Ref de **branche** (`dtolnay/rust-toolchain@stable`, `@main`) : SHA de la tête
        (`git ls-remote https://github.com/<r> refs/heads/<branche>`), commentaire `# <branche> (AAAA-MM-JJ)` ;
        Dependabot ne la suivra pas, le dire.
      - Action tierce peu connue : lire son `action.yml` (que fait-elle des secrets ?) avant de l'épingler ; une
        action qui tient en trois lignes de `run:` se remplace par ces trois lignes.
      - Images (`container:`, `services:`, `docker run`) : option, tag + digest
        (`docker buildx imagetools inspect <image>:<tag>` → `Digest:`), `<image>:<tag>@sha256:…`.
   2. **Permissions minimales** : `permissions: {}` en tête du workflow, et dans **chaque** job le strict nécessaire
      (un job sans bloc `permissions` n'a alors aucun droit, même pas cloner un dépôt privé) :

      | Le job… | Permission |
      |---|---|
      | clone le dépôt | `contents: read` |
      | pousse une image sur ghcr.io / tire une image privée | `packages: write` / `packages: read` |
      | envoie un SARIF (Code scanning) | `security-events: write` |
      | commente une PR, pose un label | `pull-requests: write` |
      | s'authentifie au cloud par OIDC | `id-token: write` |
      | déclenche un autre workflow | `actions: write` |
      | crée une release, pousse un tag | `contents: write` (seulement ce job) |

      `actions/cache` et `actions/upload-artifact` n'ont besoin d'aucune permission.
   3. **`persist-credentials: false`** sur chaque `actions/checkout` ; seule exception, un job qui pousse avec `git`
      (commentaire qui le justifie).
   4. **Pas d'injection de script** : une expression `${{ }}` dans `run:` (ou `script:` de `github-script`) est collée
      dans le script **avant** son exécution. Chercher les données contrôlables par un tiers :
      ```bash
      grep -nE '\$\{\{[^}]*(github\.event\.(issue|pull_request|comment|review|head_commit|commits|discussion|pages)|github\.head_ref|inputs\.)' .github/workflows/*.y*ml
      ```
      Celles qui sont dans un `run:` passent par `env:` (`PR_TITLE: ${{ github.event.pull_request.title }}`, puis
      `"$PR_TITLE"`). Une entrée qui choisit une version ou un chemin se valide aussi (`[[ "$TAG" =~ ^[0-9a-f]{7}$ ]]`,
      comme `release.yml`).
   5. **`pull_request_target` et `workflow_run`** : interdits par défaut (le code d'une PR de fork y tournerait avec les
      secrets et un jeton en écriture). Les remplacer par `pull_request`. S'ils sont indispensables (commenter une PR
      de fork, labeler) : ne **jamais** extraire ni exécuter le code de la PR (`ref: …head.sha` interdit), aucun
      secret, permissions minimales, et l'écrire dans `docs/SECURITE.md` (section 4).
   6. En passant : `timeout-minutes` sur chaque job ; `secrets: inherit` remplacé par la liste des secrets utiles ;
      jamais de `echo` d'un secret ni d'`env` complet dans les logs ; runner self-hosted jamais exécuté pour une PR de
      fork (`if: github.event.pull_request.head.repo.full_name == github.repository`).
   7. **Vérifier** : actionlint (section *Vérification*), et en option **zizmor**, analyseur de sécurité des workflows
      (épinglage, injections, déclencheurs, permissions, images) :
      ```bash
      docker run --rm -v "$PWD":/repo -w /repo ghcr.io/zizmorcore/zizmor:1.32.0 --offline .github/workflows
      # ou : pipx run zizmor==1.32.0 --offline .github/workflows ; sans --offline (GH_TOKEN=$(gh auth token)) il
      # vérifie aussi que chaque SHA appartient bien au dépôt de l'action et les avis connus sur les actions.
      ```
      Corriger les résultats `high` ; discuter les autres (`--persona pedantic` pour tout voir).
   8. **Dependabot** doit suivre les SHA : `.github/dependabot.yml` avec l'écosystème `github-actions` (cd-release le
      fournit ; sinon, reprendre `${CLAUDE_PLUGIN_ROOT}/skills/cd-release/templates/dependabot.yml` réduit à
      l'écosystème de l'application et à `github-actions`). Sans lui, les SHA épinglés vieillissent en silence.
10. **`docs/SECURITE.md`** depuis `templates/SECURITE.md` : remplacer `NOM_DU_PROJET`, `OUTIL_SCA`, `OUTIL_SAST`,
    `VALEUR_CSP`, `EXCEPTIONS_SCA` (le mécanisme de la stack, voir la référence), `EXCEPTIONS_WORKFLOWS` (« aucun »,
    ou ce qui reste et pourquoi), `LIMITES_DU_PROJET` (pas d'authentification, fonctions Convex à revoir, pas de
    Phoenix…) ; retirer les lignes sans objet (pas de proxy, pas de dast). Le registre reçoit les exceptions posées
    aux étapes 3 et 4. Un `docs/SECURITE.md` existant : ajouter les sections manquantes.
11. **Commits** : `ci: épingle les actions par SHA et réduit les permissions` (étape 9), puis
    `ci: ajoute les contrôles de sécurité (secrets, dépendances, SAST, DAST)` ; PR si demandé, corps qui liste les
    alertes trouvées aux étapes 3-4 et leur décision.
12. **Côté GitHub** (accord explicite, commandes montrées avant, après le push) :
    ```bash
    gh variable set STAGING_URL --body "https://staging.example.com"            # pas un secret
    gh api -X PUT "repos/{owner}/{repo}/vulnerability-alerts"                   # alertes Dependabot
    gh api -X PUT "repos/{owner}/{repo}/automated-security-fixes"               # PR de correctifs de sécurité
    gh api -X PATCH "repos/{owner}/{repo}" --input - <<'EOF'
    {"security_and_analysis": {"secret_scanning": {"status": "enabled"},
                               "secret_scanning_push_protection": {"status": "enabled"}}}
    EOF
    # Jeton des workflows en lecture seule par défaut, et pas d'approbation de PR par Actions
    gh api -X PUT "repos/{owner}/{repo}/actions/permissions/workflow" \
      -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false
    ```
    Secret scanning et push protection : gratuits sur un dépôt public ; en privé, il faut *GitHub Secret Protection*
    (payant) — la commande échoue, le noter dans les gestes manuels.
13. **Checks requis** (accord, après un premier run vert de `security.yml` sur la PR — `gh pr checks --watch`) :
    ajouter `secrets`, `dependencies`, `sast` (pas `dast` : il ne tourne pas sur les PR) au ruleset, en gardant ceux
    de `ci` :
    ```bash
    id=$(gh api "repos/{owner}/{repo}/rulesets" --jq '.[] | select(.name=="protection-main") | .id')
    gh api "repos/{owner}/{repo}/rulesets/$id" \
      | jq '{name, target, enforcement, conditions, bypass_actors,
             rules: [.rules[] | if .type == "required_status_checks"
               then .parameters.required_status_checks |= (. + [
                 {context: "secrets", integration_id: 15368},
                 {context: "dependencies", integration_id: 15368},
                 {context: "sast", integration_id: 15368}] | unique_by(.context))
               else . end]}' > ruleset-v2.json
    gh api -X PUT "repos/{owner}/{repo}/rulesets/$id" --input ruleset-v2.json \
      --jq '[.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[].context]'
    ```
    Pas de règle `required_status_checks` (ci non appliqué) : la commande n'ajoute rien ; reprendre la procédure du
    bloc ci.

## Fichiers produits

| Fichier | Source |
|---|---|
| `.github/workflows/security.yml` | `templates/security.yml` + `references/<stack>.md` |
| `.gitleaks.toml` (+ `.gitleaksignore` si besoin) | `templates/gitleaks.toml` |
| `.pre-commit-config.yaml` | `templates/pre-commit-config.yaml` |
| `.githooks/pre-commit` (exécutable, si `.githooks/`) | `templates/githooks-pre-commit` |
| `deploy/nginx/security-headers.conf` | `templates/nginx/security-headers.conf` |
| `.zap/rules.tsv` | `templates/zap-rules.tsv` |
| `docs/SECURITE.md` | `templates/SECURITE.md` |
| Modifiés : `.github/workflows/*.yml` (épinglage, permissions), `.github/dependabot.yml` si absent | étape 9 |
| Selon la stack : `.trivyignore`, `.cargo/audit.toml`, `mix.exs` (mix_audit, sobelow), `.semgrepignore` | `references/<stack>.md` |
| (hors dépôt) variable `STAGING_URL`, réglages de sécurité, checks requis | étapes 12-13 |

## Vérification

```bash
# Workflows : syntaxe, expressions, shellcheck des run: (ne doit rien afficher)
docker run --rm -v "$PWD":/repo -w /repo rhysd/actionlint:1.7.12 -color
# Plus aucune action non épinglée (ne doit rien afficher)
grep -rhnE '^\s*-?\s*uses:' .github | grep -vE '@[0-9a-f]{40}( |$)' | grep -v 'uses: *\./'
# Option : analyse de sécurité des workflows
docker run --rm -v "$PWD":/repo -w /repo ghcr.io/zizmorcore/zizmor:1.32.0 --offline .github/workflows

# Secrets : historique et arborescence (attendu : « no leaks found »)
docker run --rm -v "$PWD":/repo zricethezav/gitleaks:v8.30.1 git --redact --verbose /repo
docker run --rm -v "$PWD":/repo zricethezav/gitleaks:v8.30.1 dir --redact /repo
# La config détecte TOUJOURS un vrai secret (faux jeton GitHub, hors du dépôt) : code de sortie attendu 1
t=$(mktemp -d) && echo "token = \"ghp_$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 36)\"" > "$t/fuite.txt"
docker run --rm -v "$t":/scan -v "$PWD/.gitleaks.toml":/cfg.toml:ro zricethezav/gitleaks:v8.30.1 \
  dir --config /cfg.toml --redact /scan; echo "code : $? (attendu 1)"; rm -rf "$t"

# Hooks
pre-commit run --all-files
sh -n .githooks/pre-commit && git ls-files -s .githooks/pre-commit     # mode 100755

# Proxy : la config se charge avec les en-têtes (commande complète dans le bloc cd-release, Vérification)
tmp=$(mktemp -d) && DEPLOY_DIR=$tmp deploy/gen-cert.sh && \
  docker run --rm --add-host app:127.0.0.1 -v "$PWD/deploy/nginx/app.conf":/etc/nginx/conf.d/default.conf:ro \
    -v "$PWD/deploy/nginx":/etc/nginx/snippets:ro -v "$tmp/certs":/etc/nginx/certs:ro nginx:1.29-alpine nginx -t
# .zap/rules.tsv : 3 champs séparés par des tabulations (ne doit rien afficher)
awk -F'\t' '!/^#/ && NF != 3 {print "ligne " NR " invalide"}' .zap/rules.tsv
```

Après le push : `gh pr checks --watch` → `secrets`, `dependencies`, `sast` verts, `dast` *skipped*. Le job `dast` ne
se lance qu'une fois `security.yml` sur `main` (un `workflow_dispatch` exige que le fichier existe sur la branche par
défaut) : après la fusion, `gh workflow run security.yml --ref main`, puis lire le résumé du run et trier les alertes
(passer en `FAIL` ce qui est corrigé, justifier les `IGNORE` dans le registre). Puis
`curl -skI "$STAGING_URL" | grep -iE 'content-security|strict-transport|x-frame|x-content|referrer|permissions'`.

Preuves à proposer (pas à imposer) : une branche jetable avec une injection SQL (`references/node.md`) → `sast` rouge ;
un faux jeton dans un fichier indexé → `git commit` refusé par le hook.

## Gestes manuels à laisser à l'utilisateur

- [ ] **Secret trouvé** : le révoquer et le régénérer chez le fournisseur, mettre la nouvelle valeur dans le `.env` du
      serveur ou les secrets GitHub, vérifier les journaux d'accès (procédure `docs/SECURITE.md`, section 6). Décider
      ensuite, en connaissance de cause, s'il faut réécrire l'historique.
- [ ] Activer, si l'étape 12 n'a pas été faite : *Settings → Code security* → *Secret scanning*, *Push protection*,
      *Dependabot alerts*, *Dependabot security updates* ; *Settings → Actions → General* → *Workflow permissions* :
      *Read repository contents*, et l'obligation d'épingler les actions par SHA si l'option est proposée.
- [ ] Créer la variable de dépôt `STAGING_URL` (*Settings → Secrets and variables → Actions → Variables*) : sans
      elle, le job `dast` reste sauté.
- [ ] Cible runner local : créer le dossier de travail de ZAP visible du runner et de l'hôte (étape 8).
- [ ] Chaque poste : `pipx install pre-commit` (le hook prévient sans bloquer s'il manque) et, sans activation
      automatique, `git config core.hooksPath .githooks`.
- [ ] Après le premier run vert : ajouter `secrets`, `dependencies`, `sast` aux checks requis (étape 13).
- [ ] Après le premier scan ZAP : trier le rapport, promouvoir en `FAIL` ce qui est corrigé, justifier chaque
      `IGNORE` dans le registre de `docs/SECURITE.md`.
- [ ] Dépôt privé sans GitHub Advanced Security : retirer l'envoi SARIF (étape 5) ; secret scanning indisponible, le
      hook pre-commit et le job `secrets` restent les seuls filets.
- [ ] Revoir les exceptions à leur date (`.trivyignore` expire tout seul ; les autres non : agenda).
- [ ] Option : `SECURITY.md` (comment signaler une faille) et *Private vulnerability reporting* (*Settings → Code
      security*).
