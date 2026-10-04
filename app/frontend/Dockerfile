# Frontend = React UI (Vite + Tailwind) built with Node, served by the Quarkus BFF.
# Context: the app/ folder.  podman build -f frontend/Dockerfile -t frontend .
FROM registry.access.redhat.com/ubi9/nodejs-22 AS ui
USER 0
WORKDIR /ui/webui
COPY frontend/src/main/webui/package.json frontend/src/main/webui/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY frontend/src/main/webui/ ./
# vite outDir is ../resources/META-INF/resources -> /ui/resources/META-INF/resources
RUN npm run build

FROM registry.access.redhat.com/ubi9/openjdk-25 AS build
USER root
WORKDIR /build
COPY . .
COPY --from=ui /ui/resources/META-INF/resources/ frontend/src/main/resources/META-INF/resources/
RUN chmod +x gradlew && ./gradlew --no-daemon --console=plain :frontend:build -x test

FROM registry.access.redhat.com/ubi9/openjdk-25-runtime
ENV LANGUAGE='en_US:en'
COPY --from=build --chown=185 /build/frontend/build/quarkus-app/lib/ /deployments/lib/
COPY --from=build --chown=185 /build/frontend/build/quarkus-app/*.jar /deployments/
COPY --from=build --chown=185 /build/frontend/build/quarkus-app/app/ /deployments/app/
COPY --from=build --chown=185 /build/frontend/build/quarkus-app/quarkus/ /deployments/quarkus/
EXPOSE 8080
USER 185
ENV JAVA_OPTS_APPEND="-Dquarkus.http.host=0.0.0.0 -Djava.util.logging.manager=org.jboss.logmanager.LogManager"
ENV JAVA_APP_JAR="/deployments/quarkus-run.jar"
ENTRYPOINT [ "/opt/jboss/container/java/run/run-java.sh" ]
