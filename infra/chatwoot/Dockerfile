# The official CE workflow strips enterprise/ before compiling assets.
# Reuse its immutable image for the stage-1 baseline; no upstream code patches.
ARG CHATWOOT_CE_IMAGE
FROM ${CHATWOOT_CE_IMAGE}
ARG CHATWOOT_SOURCE_COMMIT=b2f94636d325a126a67c6c4c808303d8aa8cbeea
ENV DISABLE_ENTERPRISE=true CW_EDITION=ce
RUN test ! -d /app/enterprise \
    && test "$(cat /app/.git_sha)" = "${CHATWOOT_SOURCE_COMMIT}" \
    && ruby -I/app/lib -rchatwoot_app -e 'abort "Enterprise enabled" if ChatwootApp.enterprise?'
LABEL org.opencontainers.image.title="Corporate Chatwoot CE stage-1 lab" \
      org.opencontainers.image.revision="${CHATWOOT_SOURCE_COMMIT}"
