# monitoring : Next.js + Convex

Lire aussi `node.md` (section Next.js) : la partie Next.js s'instrumente de la même façon.

## Ce qui ne s'applique pas

| Élément du bloc | Avec Convex | Pourquoi |
|---|---|---|
| `/metrics` des fonctions Convex (queries, mutations, actions) | **Impossible** | Elles tournent chez Convex : aucun processus à nous, aucune adresse que Prometheus puisse collecter. Leurs durées, erreurs et logs se lisent dans le dashboard Convex (*Logs*, *Health*) |
| `/metrics` de Next.js | Gardé, mais **partiel** | Ne mesure que les route handlers enrobés par `withMetrics` ; la plupart des appels du navigateur vont directement à Convex (WebSocket) et n'y passent pas |
| Alertes `TauxErreur5xxEleve`, `LatenceElevee` | Gardées si des route handlers existent ; **sinon supprimées** (et le panneau RED du dashboard avec) | Sans trafic mesuré, elles ne se déclencheraient jamais : mieux vaut ne pas laisser croire qu'on surveille |
| `/health` qui teste la base | `"db":"none"`, toujours 200 si Next.js répond (bloc docker-dev) | Une panne Convex ne se répare pas en redémarrant notre conteneur |
| Alerte sur la base | Remplacée par une **sonde blackbox sur l'URL Convex** | Seul signal de disponibilité de Convex vu de chez nous |

## Ce qu'on supervise

1. **Next.js** : job `app` (`/metrics`, si des route handlers sont enrobés) et sondes `http_health` sur `/health`
   (interne et URL publique), comme pour toute application.
2. **Convex** : une sonde `http_2xx` sur l'URL du déploiement (la valeur de `NEXT_PUBLIC_CONVEX_URL`,
   `https://<déploiement>.convex.cloud`), qui répond en 2xx tant que le déploiement est servi (vérifier d'abord avec
   `curl -s -o /dev/null -w '%{http_code}' <url>`). Si le projet a une HTTP action de santé (`convex/http.ts`, servie sur
   `https://<déploiement>.convex.site/health`), la sonder plutôt : elle prouve que le code Convex s'exécute.

```yaml
# prometheus.yml : à ajouter à côté du job blackbox-health
  - job_name: blackbox-convex
    metrics_path: /probe
    params:
      module: [http_2xx] # pas le format /health commun : on vérifie seulement le 2xx
    static_configs:
      - targets: ["https://<déploiement-prod>.convex.cloud"]
        labels: { env: production, sonde: convex }
    relabel_configs: # même astuce que blackbox-health
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox:9115
```

```yaml
# rules/alertes.yml : Convex injoignable (gravité critical : l'application ne charge plus aucune donnée)
      - alert: ConvexIndisponible
        expr: probe_success{job="blackbox-convex"} == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "{{ $labels.env }} : le déploiement Convex ne répond plus"
          description: "La sonde sur {{ $labels.instance }} échoue depuis plus de 2 minutes. Voir https://status.convex.dev et le dashboard Convex."
          runbook_url: "docs/INCIDENTS.md#convexindisponible"
```

Ajouter le test `promtool` correspondant (copie du cas `AppIndisponible`) et la section `ConvexIndisponible` dans
`docs/INCIDENTS.md` (premier réflexe : page de statut Convex, puis *Logs* du dashboard Convex, puis dernier
`npx convex deploy`).

## Déploiement hébergé (Vercel…)

Si Next.js est sur une plateforme (bloc cd-release non appliqué) : rien à collecter en interne, pas de réseau Docker à
rejoindre. Le bloc se réduit à blackbox + Prometheus + Alertmanager + Grafana sur une petite machine à soi, avec
uniquement des sondes publiques (`/health` de Next.js et URL Convex). Le dire à l'utilisateur et lui demander si ça
vaut la peine, ou si les alertes de la plateforme (Vercel, Convex) suffisent.
