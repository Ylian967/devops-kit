# Incidents

Quand la production casse : on **rétablit** d'abord, on **comprend** ensuite, puis on **écrit** ce qu'on a appris
pour que ça ne se reproduise pas. Chaque incident qui a touché des utilisateurs (ou qui aurait pu) a son post-mortem
dans ce fichier, et chaque post-mortem se termine par des actions suivies dans des issues.

Les post-mortems sont **sans blâme** : on cherche ce qui, dans le système (code, pipeline, configuration, supervision,
documentation), a permis l'erreur, pas qui l'a commise. Quelqu'un qui a cassé la production avec une commande a
surtout trouvé une commande qui permettait de casser la production.

## Supervision en place

Tout est publié sur `127.0.0.1` de la machine de supervision. Depuis un autre poste, ouvrir un tunnel SSH puis les
adresses ci-dessous :

```bash
ssh -N -L 3001:127.0.0.1:3001 -L 9090:127.0.0.1:9090 -L 9093:127.0.0.1:9093 <utilisateur>@<serveur>
```

| Outil | Adresse | Sert à |
| --- | --- | --- |
| Grafana | http://localhost:3001 | dashboard *Application : disponibilité et RED* (compte `admin`) |
| Prometheus | http://localhost:9090 | *Alerts* (règles actives), *Status > Targets* (cibles et erreurs de collecte), requêtes PromQL |
| Alertmanager | http://localhost:9093 | alertes en cours, inhibées ; poser un **silence** pendant une intervention |

Les notifications partent vers : `<webhook / salon Discord / adresse mail>`.

## Alertes et premier réflexe

Les liens `runbook_url` des alertes pointent sur ces sections.

### AppIndisponible

*critical* : `/health` ne répond pas 200 + `"status":"ok"` depuis 2 min (sonde `interne` ou `publique`).

- Sonde **interne** KO : l'application ne répond plus ou sa base est injoignable (`503`, `"db":"down"`).
  `docker compose -f compose.prod.yaml ps`, puis les logs de `app` et `db`.
- Seule la sonde **publique** KO : le problème est devant l'application : proxy, certificat, DNS, pare-feu.
  `curl -v https://<domaine>/health` depuis l'extérieur, logs de `proxy`.

### CibleIllisible

*warning* : Prometheus ne collecte plus une cible depuis 2 min. *Status > Targets* donne l'erreur exacte.
`no such host` : l'environnement n'est pas démarré, ou la supervision n'a pas rejoint son réseau (redémarrer la
supervision après un premier déploiement). `connection refused` : l'application est arrêtée ou redémarre en boucle.

### TauxErreur5xxEleve

*warning* : plus de 5 % de réponses 5xx pendant 5 min. Dashboard : quelle route ? depuis quand ? la version
a-t-elle changé à ce moment (déploiement) ? Puis les logs JSON de l'application filtrés sur les erreurs :
`docker compose -f compose.prod.yaml logs --since 15m app | grep -E '"status":5[0-9]{2}'`. Si un déploiement est en
cause : revenir à la version précédente (`deploy/deploy.sh <env> $(cat .previous-tag)`), comprendre ensuite.

### LatenceElevee

*warning* : p95 au-dessus de 500 ms pendant 10 min. Dashboard : une route ou toutes ? Une route : requête lente
(index manquant, appel externe). Toutes : ressources de la machine (`docker stats`, disque plein, mémoire), base.

### CertificatExpireBientot

*warning* : le certificat public expire dans moins de 14 jours. Vérifier le renouvellement (`docs/DEPLOIEMENT.md`).

## Méthode de diagnostic

Du plus visible au plus profond. **Noter l'heure de chaque étape** : c'est la chronologie du post-mortem.

1. **L'alerte** : laquelle, quel environnement, quelle cible, depuis quand ?
2. **Le dashboard** : les courbes montent (erreurs, latence) ou **s'arrêtent** (plus de données : application
   morte) ? Que s'est-il passé juste avant (déploiement, pic de trafic) ?
3. **Le symptôme** : `curl -s https://<domaine>/health` ; ce que voit un utilisateur.
4. **Les conteneurs** : `docker compose -f compose.prod.yaml ps` (qui est `unhealthy`, `Restarting` ?).
5. **Les logs** du service suspect, sur la bonne fenêtre : `docker compose -f compose.prod.yaml logs --since 15m <service>`.
6. **La cause** : la **prouver** (fichier, `docker inspect`, requête rejouée) avant de corriger.
7. **Corriger**, puis **vérifier** : `/health` ok, sondes vertes, une action utilisateur réussie, notification *résolue*.

Intervention longue : un **silence** dans Alertmanager (durée et commentaire) évite les rappels sans supprimer l'alerte.
Le lever à la fin.

## Journal

Du plus récent au plus ancien. Un incident = une ligne ici + un post-mortem plus bas.

| N° | Date | Titre | Gravité | Durée | Actions |
| --- | --- | --- | --- | --- | --- |
| | | | | | |

## Modèle de post-mortem

Copier le bloc ci-dessous au-dessus des post-mortems existants. Le rédiger dans les jours qui suivent, pendant que
les souvenirs et les logs sont frais.

```markdown
## Incident n° N : titre court et factuel

- **Date** : AAAA-MM-JJ
- **Gravité** : faible (gêne) / moyenne (fonction dégradée) / élevée (service inutilisable ou données en danger)
- **Environnement** : production / staging
- **Détection** : alerte <nom> / signalement d'un utilisateur / par hasard ; délai entre le début et la détection
- **Durée** : de hh:mm à hh:mm (fuseau : …), soit X min
- **Rédaction** : …

### Résumé

Deux ou trois phrases : ce qui s'est passé, pour qui, combien de temps.

### Impact

Qui a été touché, comment (erreurs, lenteur, données perdues ou incohérentes), combien (requêtes en erreur, utilisateurs).

### Chronologie

- hh:mm : le changement ou l'événement à l'origine
- hh:mm : premier signal (alerte, message)
- hh:mm : ce qui a été regardé, ce qui a été trouvé (une ligne par piste, même les fausses)
- hh:mm : correction appliquée
- hh:mm : retour à la normale confirmé (sondes vertes, notification résolue)

### Cause racine

Remonter les « pourquoi » jusqu'à une cause sur laquelle on peut agir (souvent un manque de garde-fou, pas une
personne) :

1. Pourquoi … ? Parce que …
2. Pourquoi … ? Parce que …
3. …

### Ce qui a aidé

### Ce qui a freiné

### Actions

| Action | Type | Issue | Statut |
| --- | --- | --- | --- |
| … | prévention / détection / documentation | #… | à faire |
```

<!-- Post-mortems : du plus récent au plus ancien, sous cette ligne. -->
