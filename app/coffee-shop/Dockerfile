# coffee-shop = React UI (Vite + Tailwind) built with Node, served by Quarkus.
# Context: the app/ folder.  podman build -f coffee-shop/Dockerfile -t coffee-shop .
FROM registry.access.redhat.com/ubi9/nodejs-22 AS ui
USER 0
WORKDIR /ui/webui
COPY coffee-shop/src/main/webui/package.json coffee-shop/src/main/webui/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY coffee-shop/src/main/webui/ ./
# vite outDir is ../resources/META-INF/resources -> /ui/resources/META-INF/resources
RUN npm run build

FROM registry.access.redhat.com/ubi9/openjdk-25 AS build
USER root
WORKDIR /build
COPY . .
COPY --from=ui /ui/resources/META-INF/resources/ coffee-shop/src/main/resources/META-INF/resources/
RUN chmod +x gradlew && ./gradlew --no-daemon --console=plain :coffee-shop:build -x test

FROM registry.access.redhat.com/ubi9/openjdk-25-runtime
ENV LANGUAGE='en_US:en'
COPY --from=build --chown=185 /build/coffee-shop/build/quarkus-app/lib/ /deployments/lib/
COPY --from=build --chown=185 /build/coffee-shop/build/quarkus-app/*.jar /deployments/
COPY --from=build --chown=185 /build/coffee-shop/build/quarkus-app/app/ /deployments/app/
COPY --from=build --chown=185 /build/coffee-shop/build/quarkus-app/quarkus/ /deployments/quarkus/
EXPOSE 8080
USER 185
ENV JAVA_OPTS_APPEND="-Dquarkus.http.host=0.0.0.0 -Djava.util.logging.manager=org.jboss.logmanager.LogManager"
ENV JAVA_APP_JAR="/deployments/quarkus-run.jar"
ENTRYPOINT [ "/opt/jboss/container/java/run/run-java.sh" ]
