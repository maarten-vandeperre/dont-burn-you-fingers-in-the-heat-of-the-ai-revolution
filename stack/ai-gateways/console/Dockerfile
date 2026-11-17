# Built in the cluster by: ./deploy.sh ai-gateways console (BuildConfig ai-gateway-console, binary)
FROM registry.access.redhat.com/ubi9/nodejs-20:latest AS build
WORKDIR /opt/app-root/src
COPY --chown=1001:0 package.json package-lock.json* ./
RUN npm ci --no-audit --no-fund
COPY --chown=1001:0 . .
RUN npm run build && npm prune --omit=dev

FROM registry.access.redhat.com/ubi9/nodejs-20-minimal:latest
WORKDIR /opt/app-root/src
COPY --from=build /opt/app-root/src/node_modules ./node_modules
COPY --from=build /opt/app-root/src/dist ./dist
COPY --from=build /opt/app-root/src/server ./server
COPY --from=build /opt/app-root/src/package.json ./
ENV PORT=8080 NODE_ENV=production
EXPOSE 8080
USER 1001
CMD ["node", "server/index.mjs"]
