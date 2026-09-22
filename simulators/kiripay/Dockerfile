FROM docker.io/library/ruby:3.3.12-slim
WORKDIR /sim
RUN apt-get update -qq && apt-get install -y --no-install-recommends build-essential && rm -rf /var/lib/apt/lists/*
COPY Gemfile Gemfile.lock ./
RUN bundle install
COPY . .
EXPOSE 4002
CMD ["bundle", "exec", "puma", "-p", "4002", "-b", "tcp://0.0.0.0", "config.ru"]
