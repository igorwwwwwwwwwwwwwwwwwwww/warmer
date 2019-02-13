# frozen_string_literal: true

libdir = File.expand_path('./lib', __dir__)
$LOAD_PATH.unshift(libdir) unless $LOAD_PATH.include?(libdir)

require 'warmer'

if ENV.key?('DYNO')
  $stdout.sync = true
  $stderr.sync = true
  STDOUT.sync = true
  STDERR.sync = true
end

unless %w[development test].include?(ENV['RACK_ENV'] || 'bogus')
  require 'rack/ssl'
  use Rack::SSL

  require 'honeycomb-beeline'
  use Rack::Honeycomb::Middleware
end

run Warmer::App
