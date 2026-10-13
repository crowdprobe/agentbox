# Intentionally unsafe negative fixture for scripts/lint_downloads.sh.
# CI scans this file as text and must reject it; this image is never built.
FROM debian:trixie-slim
RUN curl --proto '=https' --tlsv1.2 -fsSL https://example.com/install.sh | sh
