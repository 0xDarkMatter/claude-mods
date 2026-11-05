# Fixture: one image reference of each offline status, plus live answers in answers.json.
FROM node:24-slim AS build
FROM gcr.io/distroless/nodejs24-debian13:nonroot
COPY --from=build /app /app
COPY --from=ghcr.io/astral-sh/uv:0.9.0 /uv /usr/local/bin/uv
FROM python:${PY_VERSION}-slim
FROM ubuntu
FROM myapp:1.0
FROM Node:24
