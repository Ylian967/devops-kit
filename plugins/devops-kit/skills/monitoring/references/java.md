# monitoring : Java (Spring Boot)

Spring Boot mesure déjà chaque requête HTTP avec **Micrometer** ; **Actuator** publie ces mesures au format
Prometheus. Il reste à choisir le chemin, à obtenir un vrai histogramme, et à aligner les noms sur le contrat commun.

## Dépendances

```xml
<!-- pom.xml -->
<dependency>
  <groupId>org.springframework.boot</groupId>
  <artifactId>spring-boot-starter-actuator</artifactId>
</dependency>
<dependency>
  <groupId>io.micrometer</groupId>
  <artifactId>micrometer-registry-prometheus</artifactId>
  <scope>runtime</scope>
</dependency>
```

Gradle : `implementation("org.springframework.boot:spring-boot-starter-actuator")` et
`runtimeOnly("io.micrometer:micrometer-registry-prometheus")`. Versions gérées par le BOM Spring Boot : ne pas en écrire.

## Le chemin : `/metrics` plutôt que `/actuator/prometheus`

```properties
# application.properties
# N'exposer en HTTP QUE l'endpoint prometheus (pas env, beans, heapdump… qui fuient des secrets).
management.endpoints.web.exposure.include=prometheus
# Servi à la racine, sous le nom commun : GET /metrics (déjà bloqué par deploy/nginx/app.conf).
management.endpoints.web.base-path=/
management.endpoints.web.path-mapping.prometheus=metrics
# Vrai histogramme, avec des tranches choisies (sinon : pas de _bucket, donc pas de p95).
# Les mêmes que les autres stacks : elles encadrent le seuil de l'alerte (500 ms).
management.metrics.distribution.slo.http.server.requests=5ms,10ms,25ms,50ms,100ms,250ms,500ms,1s,2.5s,5s
```

- `/health` reste le contrôleur au format commun (bloc docker-dev) : `health` n'est pas exposé par Actuator, il n'y a
  donc pas de conflit avec `base-path=/`.
- Spring Security : `requestMatchers("/metrics").permitAll()` (Prometheus ne s'authentifie pas ; la protection est le
  réseau : le proxy renvoie 404).
- **Plus strict** (conseillé si l'application est exposée sans le proxy de cd-release) : un port de gestion séparé,
  jamais routé par le proxy : `management.server.port=8081`, et la cible devient `monapp-production-app-1:8081` dans
  `prometheus.yml`.
- Garder `/actuator/prometheus` (projet existant, autre outil qui l'utilise) : ne pas toucher au chemin, mettre
  `metrics_path: /actuator/prometheus` dans le job `app`, et vérifier que le proxy bloque bien `/actuator`
  (`references/stacks.md` du bloc cd-release).

Port : 8080 dans les cibles de `prometheus.yml` (sondes `/health` comprises).

## Les noms : renommés par Prometheus

Micrometer publie `http_server_requests_seconds_{count,sum,bucket}{method,uri,status,outcome,exception}`, pas
`http_requests_total` ni `http_request_duration_seconds`. Plutôt que du code Java, un renommage **à la collecte**,
dans le job `app` de `prometheus.yml` :

```yaml
  - job_name: app
    # … static_configs inchangées
    metric_relabel_configs:
      # le nombre de requêtes de l'histogramme devient le compteur commun
      - source_labels: [__name__]
        regex: http_server_requests_seconds_count
        target_label: __name__
        replacement: http_requests_total
      # tranches et somme deviennent l'histogramme commun
      - source_labels: [__name__]
        regex: http_server_requests_seconds_(bucket|sum)
        target_label: __name__
        replacement: http_request_duration_seconds_$1
      # uri (déjà le motif : /tasks/{id}, UNKNOWN pour les 404) recopié dans route
      - source_labels: [uri]
        regex: (.+)
        target_label: route
```

`outcome` et `exception` restent (les règles agrègent par `env`, ils ne gênent pas ; les supprimer pourrait créer
deux séries identiques et faire échouer la collecte). `uri` est sûr pour la cardinalité : Spring y met le motif du
`@GetMapping`, jamais l'URL réelle.

Vérifier après démarrage : `curl -s localhost:8080/metrics | grep -E '^http_server_requests_seconds_bucket' | head -3`
(des lignes `le="0.5"` doivent apparaître), puis dans Prometheus `http_requests_total{job="app"}`.

## Test

`@SpringBootTest(webEnvironment = RANDOM_PORT)` + `TestRestTemplate` (ou `MockMvc` avec
`@AutoConfigureObservability`, sans laquelle les métriques sont désactivées en test) : appeler `/tasks/1`, puis
`GET /metrics` → 200, `text/plain`, contient `uri="/tasks/{id}"`, `le="0.5"`, et pas `/tasks/1`.

## Quarkus, Micronaut

Quarkus : extension `quarkus-micrometer-registry-prometheus` (`/q/metrics`, chemin réglable par
`quarkus.micrometer.export.prometheus.path=/metrics`) ; mêmes noms Micrometer, même renommage. Micronaut :
`micronaut-micrometer-registry-prometheus` (`/prometheus`) ; idem.
