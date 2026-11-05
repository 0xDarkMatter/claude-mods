FROM node:24 AS builder
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
FROM nginx:alpine
COPY --from=builder . /srv/app
