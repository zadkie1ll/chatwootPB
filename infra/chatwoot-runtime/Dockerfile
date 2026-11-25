# A bounded runtime patch; no dependency installation or frontend compilation.
ARG BASE_IMAGE=corporate-chatwoot-ce:server
FROM ${BASE_IMAGE}
COPY db_enhancements.rake /app/lib/tasks/db_enhancements.rake
