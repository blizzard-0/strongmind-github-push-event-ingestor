# syntax=docker/dockerfile:1

ARG RUBY_VERSION=3.3.10

FROM ruby:${RUBY_VERSION}-slim-bookworm AS base

ENV APP_HOME=/rails \
    BUNDLE_DEPLOYMENT=1 \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT="" \
    RAILS_LOG_TO_STDOUT=1

WORKDIR ${APP_HOME}

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libpq5 && \
    rm -rf /var/lib/apt/lists/*

FROM base AS build

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libpq-dev && \
    rm -rf /var/lib/apt/lists/*

COPY Gemfile Gemfile.lock ./
RUN bundle install && \
    rm -rf /usr/local/bundle/ruby/*/cache

COPY . .
RUN bundle exec bootsnap precompile --gemfile app/ lib/

FROM base

RUN groupadd --system --gid 1000 rails && \
    useradd --system --uid 1000 --gid 1000 --create-home rails

COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=build --chown=rails:rails ${APP_HOME} ${APP_HOME}

USER rails

ENTRYPOINT ["./bin/docker-entrypoint"]
EXPOSE 3000
CMD ["bin/rails", "server", "--binding", "0.0.0.0"]
