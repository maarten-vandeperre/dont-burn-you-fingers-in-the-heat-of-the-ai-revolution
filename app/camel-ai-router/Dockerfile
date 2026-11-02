# camel-ai-router: Quarkus + Apache Camel, no UI.
FROM registry.access.redhat.com/ubi9/openjdk-25 AS build
USER root
WORKDIR /build
COPY . .
RUN chmod +x gradlew && ./gradlew --no-daemon --console=plain build -x test

FROM registry.access.redhat.com/ubi9/openjdk-25-runtime
ENV LANGUAGE='en_US:en'
COPY --from=build --chown=185 /build/build/quarkus-app/lib/ /deployments/lib/
COPY --from=build --chown=185 /build/build/quarkus-app/*.jar /deployments/
COPY --from=build --chown=185 /build/build/quarkus-app/app/ /deployments/app/
COPY --from=build --chown=185 /build/build/quarkus-app/quarkus/ /deployments/quarkus/
EXPOSE 8080
USER 185
ENV JAVA_OPTS_APPEND="-Dquarkus.http.host=0.0.0.0 -Djava.util.logging.manager=org.jboss.logmanager.LogManager"
ENV JAVA_APP_JAR="/deployments/quarkus-run.jar"
ENTRYPOINT [ "/opt/jboss/container/java/run/run-java.sh" ]
