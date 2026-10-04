# ${{ values.name }}: React UI (built with Node) served by the Quarkus backend.
#   podman build -t ${{ values.name }} .
FROM registry.access.redhat.com/ubi9/nodejs-22 AS ui
USER root
WORKDIR /ui
COPY src/main/webui/package.json ./
RUN npm install --no-audit --no-fund
COPY src/main/webui/ ./
RUN npm run build

FROM registry.access.redhat.com/ubi9/openjdk-25 AS build
USER root
WORKDIR /build
COPY . .
COPY --from=ui /resources/META-INF/resources/ src/main/resources/META-INF/resources/
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
