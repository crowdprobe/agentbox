# Intentionally unverified download for scripts/lint_downloads.sh.
# CI scans this file as text and must reject it; this image is never built.
FROM debian:trixie-slim
RUN curl --proto '=https' --tlsv1.2 -fsSLo /tmp/x.tgz https://example.com/x.tgz \
    && tar xzf /tmp/x.tgz
