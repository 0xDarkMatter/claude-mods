# Fixture: every Dockerfile landmine docker-audit.py checks for. Not a real image.
# syntax=docker/dockerfile:1
ARG BASE
FROM node:20-slim AS build
WORKDIR app
MAINTAINER someone@example.com
ARG NPM_TOKEN
ENV API_KEY=changeme-fixture-value
COPY . .
RUN npm install
RUN apt-get update
RUN apt install -y curl
RUN curl -fsSLk https://example.com/install.sh | sh
RUN cd /tmp && wget --no-check-certificate https://example.com/x.tgz
RUN pip install -r requirements.txt
COPY .npmrc /root/.npmrc
ADD https://example.com/tool.tar.gz /opt/
ADD config.json /etc/app/
RUN sudo apk add jq
RUN --mount=type=ssh GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=no" git clone git@example.com:org/repo.git
RUN --mount=type=secret,id=npm npm ci
RUN --mount=type=cache,target=/var/cache/apt apt-get update && apt-get install -y --no-install-recommends git
EXPOSE 22
CMD node server.js
CMD ["node", "server.js"]

FROM ${BASE} AS other

FROM python:3.9-slim AS build
COPY --from=other /app /app
HEALTHCHECK CMD curl -f http://localhost:8000/health
