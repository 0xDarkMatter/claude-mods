# check=skip=JSONArgsRecommended
FROM gcr.io/distroless/static-debian13:nonroot
COPY app /app
HEALTHCHECK CMD /app healthz
CMD /app
