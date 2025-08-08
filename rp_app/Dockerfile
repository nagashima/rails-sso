FROM ruby:3.2.6-slim

# 環境変数設定
ENV RAILS_ENV="development" \
    BUNDLE_PATH="/usr/local/bundle" \
    LANG="C.UTF-8" \
    TZ="Asia/Tokyo"

# パッケージインストール
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
    build-essential \
    default-libmysqlclient-dev && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Gemfile コピー & bundle install
COPY Gemfile Gemfile.lock ./
RUN bundle install

EXPOSE 3001

CMD ["bundle", "exec", "rails", "server", "-b", "0.0.0.0"]
