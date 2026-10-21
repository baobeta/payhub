# syntax=docker/dockerfile:1
#
# Two images from one file:
#   docker build --target production -t payhub .   # what runs in production (README "Production image")
#   docker compose up                              # builds the dev target
#
# The production image is the default (last) target: non-root, no compilers,
# no node, gems for production only, Vite bundles and bootsnap precompiled.

ARG RUBY_VERSION=3.3.12

# ── base: what every image needs at runtime ──────────────────────────────────
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

WORKDIR /rails

# libpq5 for pg; psql because db:prepare loads db/structure.sql with it;
# jemalloc for memory (bin/docker-entrypoint preloads it); curl for health checks.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 libpq5 postgresql-client && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

ENV BUNDLE_PATH=/usr/local/bundle

# ── toolchain: compilers and node, for installing gems and building bundles ──
FROM base AS toolchain

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libpq-dev && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Node for Vite (UI bundles). Copied from the official image to avoid a PPA.
COPY --from=docker.io/library/node:22-slim /usr/local/bin/node /usr/local/bin/node
COPY --from=docker.io/library/node:22-slim /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm && \
    ln -s /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx

# ── dev: what docker-compose runs (every gem group, node_modules, Vite dev server) ──
FROM toolchain AS dev

COPY Gemfile Gemfile.lock ./
RUN bundle install

COPY package.json package-lock.json ./
RUN npm ci

COPY . .

# Compose bind-mounts the checkout over /rails, so this runs the host's copy.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]
EXPOSE 3000
CMD ["bin/rails", "server", "-b", "0.0.0.0"]

# ── build: production gems, bootsnap cache and Vite bundles ──────────────────
FROM toolchain AS build

ENV BUNDLE_DEPLOYMENT=1 BUNDLE_WITHOUT="development:test"

COPY Gemfile Gemfile.lock ./
RUN bundle install && \
    rm -rf ~/.bundle "$BUNDLE_PATH"/ruby/*/cache "$BUNDLE_PATH"/ruby/*/bundler/gems/*/.git && \
    bundle exec bootsnap precompile --gemfile

COPY package.json package-lock.json ./
RUN npm ci

COPY . .

# bin/vite build is the vite_ruby CLI: it reads config/vite.json and runs
# Vite, without booting Rails, so the production boot checks (AR_ENCRYPTION_*,
# PSP credentials) never run here and no secret, real or dummy, is needed.
# Output: public/vite (the production default of vite.json's publicOutputDir).
RUN bundle exec bootsnap precompile app/ lib/ && \
    RAILS_ENV=production bin/vite build && \
    rm -rf node_modules

# ── production ───────────────────────────────────────────────────────────────
FROM base AS production

# PROMETHEUS_MULTIPROC_DIR: one directory per container, on the container's
# own disk (never a shared volume); bin/docker-entrypoint wipes it at start.
# RUNBOOK "Metrics across processes".
ENV RAILS_ENV=production \
    BUNDLE_DEPLOYMENT=1 \
    BUNDLE_WITHOUT="development:test" \
    PROMETHEUS_MULTIPROC_DIR=/rails/tmp/prometheus

COPY --from=build "$BUNDLE_PATH" "$BUNDLE_PATH"
COPY --from=build /rails /rails

# The code stays root-owned and read-only to the app; only tmp and log are its own.
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    mkdir -p tmp log && chown -R rails:rails tmp log
USER 1000:1000

ENTRYPOINT ["/rails/bin/docker-entrypoint"]
EXPOSE 3000
# Web. The worker runs from the same image: docker run … payhub bundle exec sidekiq
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
