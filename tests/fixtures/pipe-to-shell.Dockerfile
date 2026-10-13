# Intentionally unsafe negative fixture for scripts/lint_downloads.sh.
# CI scans this file as text and must reject it; this image is never built.
FROM debian
RUN curl -fsSL https://example.com/install.sh | sh
