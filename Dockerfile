FROM ruby:2.6

ENV RACK_ENV production
ENV PORT 3000

RUN gem install bundler

WORKDIR /app
COPY Gemfile Gemfile.lock ./
RUN bundle install --without development test

COPY . .

EXPOSE 3000
CMD bin/travis-warmer-server
