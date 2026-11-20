# ci : Java (Maven et Gradle)

Templates : `templates/ci-java-maven.yml`, `templates/ci-java-gradle.yml`.
Toujours le **wrapper** (`./mvnw`, `./gradlew`) : la version de l'outil est figée dans le dépôt. S'il manque, proposer de
le générer (`mvn wrapper:wrapper`, `gradle wrapper`) ; à défaut, remplacer `./mvnw` par `mvn`. Vérifier le bit
exécutable (`git ls-files -s mvnw gradlew` → `100755`, sinon `git add --chmod=+x`).

Version de Java : celle de `<maven.compiler.release>` / `<java.version>` (Spring Boot) ou de la toolchain Gradle.

## Lint

Selon les plugins présents (ne pas en ajouter sans accord) :

| Outil | Maven | Gradle |
|---|---|---|
| Spotless (formatage) | `spotless:check` | `spotlessCheck` |
| Checkstyle | `checkstyle:check` | `checkstyleMain checkstyleTest` |
| Aucun | proposer Spotless avec `palantirJavaFormat` ou `googleJavaFormat` | idem |

Aucun outil et refus d'en ajouter : le job `lint` fait au moins `./mvnw -q compile -Dmaven.compiler.failOnWarning=true`
(ou `./gradlew compileJava` avec `options.compilerArgs << '-Werror'`).

## Maven : séparer unitaires et intégration

Convention : **Surefire** lance les `*Test.java` (phase `test`), **Failsafe** les `*IT.java` (phase `integration-test`).
Deux propriétés permettent de lancer l'un sans l'autre :

```xml
<properties>
  <skipUTs>false</skipUTs>   <!-- -DskipUTs : saute les tests unitaires (job integration) -->
  <!-- skipITs est déjà reconnu par Failsafe : -DskipITs saute l'intégration (job test) -->
</properties>

<plugin>
  <artifactId>maven-surefire-plugin</artifactId>
  <configuration><skipTests>${skipUTs}</skipTests></configuration>
</plugin>
<plugin>
  <artifactId>maven-failsafe-plugin</artifactId>
  <executions><execution><goals><goal>integration-test</goal><goal>verify</goal></goals></execution></executions>
</plugin>
```

## Seuil de couverture : JaCoCo

Maven (le `check` s'exécute dans `verify` et fait échouer le build sous le seuil) :

```xml
<plugin>
  <groupId>org.jacoco</groupId>
  <artifactId>jacoco-maven-plugin</artifactId>
  <executions>
    <execution><id>prepare</id><goals><goal>prepare-agent</goal></goals></execution>   <!-- instrumente les tests -->
    <execution><id>report</id><phase>verify</phase><goals><goal>report</goal></goals></execution>
    <execution>
      <id>check</id><goals><goal>check</goal></goals>
      <configuration><rules><rule>
        <element>BUNDLE</element>                                  <!-- tout le module -->
        <limits><limit><counter>LINE</counter><value>COVEREDRATIO</value><minimum>0.80</minimum></limit></limits>
      </rule></rules></configuration>
    </execution>
  </executions>
</plugin>
```

Gradle (Kotlin DSL) :

```kotlin
plugins { jacoco }
tasks.jacocoTestCoverageVerification {
    violationRules { rule { limit { counter = "LINE"; minimum = "0.80".toBigDecimal() } } }
}
tasks.check { dependsOn(tasks.jacocoTestCoverageVerification) }
```

## Gradle : une suite `integrationTest`

```kotlin
testing {
    suites {
        register<JvmTestSuite>("integrationTest") {      // sources dans src/integrationTest/java
            dependencies { implementation(project()) }
        }
    }
}
```

## Base de données

- **Testcontainers** déjà présent : il démarre lui-même PostgreSQL dans Docker, disponible sur `ubuntu-latest`. Garder
  le job `integration` mais supprimer `services:` et `env:`.
- Sinon : le service PostgreSQL du template ; Spring Boot lit `SPRING_DATASOURCE_*` à la place de
  `spring.datasource.*`. Hors Spring, adapter les noms de variables à ce que lit l'application.
- Flyway / Liquibase : les migrations tournent au démarrage du contexte de test, rien à ajouter.
