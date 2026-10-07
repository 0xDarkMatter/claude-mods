# syntax=docker/dockerfile:1
# Fixture: the base-pinning checks the bad fixture does not reach.
FROM ubuntu AS fetch
RUN echo fetch

FROM alpine:latest
USER 65532
CMD ["/bin/true"]
