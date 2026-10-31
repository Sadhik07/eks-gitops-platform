# syntax=docker/dockerfile:1.7
# Unprivileged nginx: runs as UID 101 and listens on 8080, so it passes the
# run-as-non-root Kyverno policy without extra capabilities.
FROM nginxinc/nginx-unprivileged:1.31-alpine

# Pull in Alpine security fixes released after the base image was built, so the
# Trivy gate (fixable HIGH/CRITICAL) passes on every rebuild.
USER root
# hadolint ignore=DL3017
RUN apk upgrade --no-cache
USER 101

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html /usr/share/nginx/html/index.html
EXPOSE 8080
