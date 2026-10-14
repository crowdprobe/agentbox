# Intentionally missing a Renovate annotation for scripts/lint_downloads.sh.
# CI scans this file as text and must reject it; this image is never built.
FROM debian:trixie-slim
USER 65534
ARG FOO_VERSION=1.2.3
