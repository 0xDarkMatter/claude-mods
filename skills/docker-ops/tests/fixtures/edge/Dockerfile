# syntax=docker/dockerfile:1
# Fixture: suppression pragmas, alpine tooling, an explicit root user, a redacted URL.
FROM alpine:3.22
# hadolint ignore=DL3019
RUN apk add curl
# docker-audit ignore=sudo-in-run reason="the fixture needs sudo here"
RUN sudo true
# docker-audit ignore=sudo-in-run
RUN sudo false
# docker-audit ignore=cd-in-run reason="kept for the fixture" until=2020-01-01
RUN cd /tmp
# docker-audit ignore=no-such-check reason="the fixture names a check that does not exist"
RUN echo hi
ADD https://user:hunter2-fixture@example.com/f.tgz /opt/
COPY secrets/ /opt/secrets/
USER root
HEALTHCHECK CMD wget -q -O- http://localhost/
LABEL org.opencontainers.image.source="https://example.com/repo"
CMD ["/bin/app"]
