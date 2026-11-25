ARG NODE_IMAGE
ARG CHATWOOT_CE_IMAGE
FROM --platform=$BUILDPLATFORM ${NODE_IMAGE} AS node
FROM --platform=$BUILDPLATFORM ${CHATWOOT_CE_IMAGE} AS frontend
ENV DISABLE_ENTERPRISE=true CW_EDITION=ce CORPORATE_ACCESS_ENABLED=false
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -sf /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && npm install -g pnpm@10.2.0
WORKDIR /app
COPY chatwoot/package.json chatwoot/pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile
COPY chatwoot/app/javascript /app/app/javascript
COPY chatwoot/vite.config.ts chatwoot/vite.shared.ts chatwoot/tailwind.config.js chatwoot/tailwind.superadmin.config.js chatwoot/postcss.config.js chatwoot/.browserslistrc ./
RUN SECRET_KEY_BASE=local_asset_build_placeholder NODE_OPTIONS=--max-old-space-size=4096 bundle exec rake assets:precompile

FROM ${CHATWOOT_CE_IMAGE} AS production
ENV DISABLE_ENTERPRISE=true CW_EDITION=ce CORPORATE_ACCESS_ENABLED=true
COPY chatwoot/app /app/app
COPY chatwoot/lib /app/lib
COPY chatwoot/config /app/config
COPY chatwoot/db /app/db
COPY --from=frontend /app/public /app/public
RUN test ! -d /app/enterprise \
    && ruby -I/app/lib -rchatwoot_app -e 'abort "Enterprise enabled" if ChatwootApp.enterprise?'

FROM frontend AS test
COPY chatwoot/app /app/app
COPY chatwoot/lib /app/lib
COPY chatwoot/config /app/config
COPY chatwoot/db /app/db
ENV BUNDLE_WITHOUT="" CORPORATE_ACCESS_ENABLED=true
RUN apk add --no-cache postgresql-dev linux-headers \
    && bundle config set without '' \
    && bundle install -j 4
COPY chatwoot/spec /app/spec
COPY chatwoot/.rspec chatwoot/.rubocop.yml chatwoot/.eslintrc.js chatwoot/vitest.config.ts chatwoot/vitest.setup.js chatwoot/vitest.i18n.js ./
