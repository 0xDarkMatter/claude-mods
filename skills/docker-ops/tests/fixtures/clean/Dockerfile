# syntax=docker/dockerfile:1
# Fixture: a Dockerfile docker-audit.py must find nothing wrong with (false-positive guard).
FROM node:24-slim AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci --omit=dev

FROM node:24-slim
WORKDIR /app
RUN rm -f /etc/apt/apt.conf.d/docker-clean
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends tini
COPY --from=deps /app/node_modules ./node_modules
COPY --chown=node:node . .
LABEL org.opencontainers.image.source="https://example.com/repo"
USER node
EXPOSE 3000
HEALTHCHECK CMD ["node", "healthcheck.js"]
ENTRYPOINT ["tini", "--"]
CMD ["node", "server.js"]
