# docker-dev : Java (Maven, Gradle)

Templates : `templates/Dockerfile.java-maven`, `templates/Dockerfile.java-gradle`. Écrits pour **Spring Boot 3.3+**
(extraction en couches `-Djarmode=tools`). Autre framework : voir la fin.

## Adapter le Dockerfile

| Situation | Changement |
|---|---|
| `<java.version>` / `toolchain` ≠ 21 | Changer les deux images (`maven:…-eclipse-temurin-<v>` ou `gradle:…-jdk<v>`, et `eclipse-temurin:<v>…-jre-noble`) |
| Wrapper présent (`mvnw`, `gradlew`) | Option : partir de `eclipse-temurin:<v>-jdk-noble` et lancer `./mvnw` / `./gradlew` pour la même version d'outil qu'en local (copier aussi `.mvn/` ou `gradle/`) |
| Gradle Groovy | `settings.gradle` et `build.gradle` au lieu de `.kts` |
| Multi-modules | Copier tous les `pom.xml` / `build.gradle.kts` avant `dependency:go-offline`, puis construire le module exécutable (`-pl app -am`) |
| Spring Boot < 3.3 | Remplacer l'extraction par `java -Djarmode=layertools -jar app.jar extract` et `org.springframework.boot.loader.JarLauncher` (sans `.launch`) |

Le port : `server.port=${PORT:8080}` dans `application.properties` (Spring lit aussi `SERVER_PORT` tout seul).

## Route /health

Spring Boot Actuator donne `/actuator/health` (avec l'état de la base via `DataSourceHealthIndicator`, 503 si elle est
`DOWN`), mais pas au format devops-kit. Deux options, proposer la première :

1. **Un contrôleur `/health`** au format commun :

   ```java
   // HealthController.java : format commun devops-kit (statut, base, version, env).
   @RestController
   class HealthController {
     private final JdbcTemplate jdbc;
     HealthController(JdbcTemplate jdbc) { this.jdbc = jdbc; }

     @GetMapping("/health")
     ResponseEntity<Map<String, String>> health() {
       String version = System.getenv().getOrDefault("APP_VERSION", "dev");
       String env = System.getenv().getOrDefault("APP_ENV", "local");
       try {
         jdbc.queryForObject("SELECT 1", Integer.class);   // la base répond-elle vraiment ?
         return ResponseEntity.ok(Map.of("status", "ok", "db", "up", "version", version, "env", env));
       } catch (Exception e) {
         return ResponseEntity.status(503).body(Map.of("status", "degraded", "db", "down", "version", version, "env", env));
       }
     }
   }
   ```
   Délai court : `spring.datasource.hikari.connection-timeout=2000` (2 s ; 30 s par défaut).
   Spring Security : `requestMatchers("/health").permitAll()`.
2. **Garder Actuator** : `management.endpoints.web.exposure.include=health,prometheus`, et pointer healthchecks et
   smoke test sur `/actuator/health`. Le smoke test de `cd-release` cherche `"status":"ok"` : Actuator renvoie
   `"UP"`, il faut alors adapter `smoke-test.sh`. D'où la préférence pour l'option 1.

Test : `@WebMvcTest(HealthController.class)` avec un `JdbcTemplate` simulé (`@MockitoBean`) qui réussit puis lève une
exception → 200 puis 503.

## Healthcheck

L'image `eclipse-temurin` (Ubuntu) contient `curl` : le template s'en sert. Image sans curl (distroless, alpine
minimale) : `bash -c 'exec 3<>/dev/tcp/127.0.0.1/8080 …'` (voir `Dockerfile.elixir`) si bash existe, sinon un
healthcheck uniquement dans `compose.yaml` lancé depuis un autre conteneur.

## compose.yaml

Port 8080. Spring lit `SPRING_DATASOURCE_URL=jdbc:postgresql://db:5432/app`, `SPRING_DATASOURCE_USERNAME`,
`SPRING_DATASOURCE_PASSWORD` : les mettre dans `environment:` de `app` **à la place** de `DATABASE_URL` (format JDBC,
sans identifiants dans l'URL). `start_period` de 60 s : la JVM démarre lentement.

## Autres frameworks

Quarkus : `quarkus-smallrye-health` (`/q/health`) ou un endpoint `/health` équivalent ; image JVM
`eclipse-temurin:<v>-jre` + `target/quarkus-app/`. Micronaut : `micronaut-management` (`/health`, à adapter au format).
