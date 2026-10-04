# Builds one backend service. Context: the app/ folder. Build arg SERVICE = gradle project name.
#   podman build -f Dockerfile --build-arg SERVICE=rag-service -t rag-service .
# On OpenShift: app/demo.sh build (binary builds) or the Tekton pipeline in deploy/pipelines.
FROM registry.access.redhat.com/ubi9/openjdk-25 AS build
ARG SERVICE
USER root
WORKDIR /build
COPY . .
RUN chmod +x gradlew && ./gradlew --no-daemon --console=plain ":${SERVICE}:build" -x test

FROM registry.access.redhat.com/ubi9/openjdk-25-runtime
ARG SERVICE
ENV LANGUAGE='en_US:en'
COPY --from=build --chown=185 /build/${SERVICE}/build/quarkus-app/lib/ /deployments/lib/
COPY --from=build --chown=185 /build/${SERVICE}/build/quarkus-app/*.jar /deployments/
COPY --from=build --chown=185 /build/${SERVICE}/build/quarkus-app/app/ /deployments/app/
COPY --from=build --chown=185 /build/${SERVICE}/build/quarkus-app/quarkus/ /deployments/quarkus/
EXPOSE 8080
USER 185
ENV JAVA_OPTS_APPEND="-Dquarkus.http.host=0.0.0.0 -Djava.util.logging.manager=org.jboss.logmanager.LogManager"
ENV JAVA_APP_JAR="/deployments/quarkus-run.jar"
ENTRYPOINT [ "/opt/jboss/container/java/run/run-java.sh" ]
