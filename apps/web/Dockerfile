# syntax=docker/dockerfile:1.7
# Unprivileged nginx: runs as UID 101 and listens on 8080, so it passes the
# run-as-non-root Kyverno policy without extra capabilities.
FROM nginxinc/nginx-unprivileged:1.31-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html /usr/share/nginx/html/index.html
EXPOSE 8080
