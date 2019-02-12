# frozen_string_literal: true

require 'simplecov'

require 'json'

require 'fakeredis'
require 'rack/test'

libdir = File.expand_path('../lib', __dir__)
$LOAD_PATH.unshift(libdir) unless $LOAD_PATH.include?(libdir)

require 'warmer'

Warmer.logger.level = :fatal
