# frozen_string_literal: true

require_relative 'travis'

require 'connection_pool'
require 'google/apis/compute_v1'
require 'redis-namespace'
require 'travis/logger'

module Warmer
  autoload :App, 'warmer/app'
  autoload :Config, 'warmer/config'
  autoload :Matcher, 'warmer/matcher'
  autoload :InstanceChecker, 'warmer/instance_checker'

  def config
    @config ||= Warmer::Config.load
  end

  module_function :config

  def logger
    @logger ||= Travis::Logger.new(@logdev || $stdout, config)
  end

  module_function :logger

  attr_writer :logdev
  module_function :logdev=

  def version
    @version ||=
      `git rev-parse HEAD 2>/dev/null || echo ${SOURCE_VERSION:-fafafaf}`.strip
  end

  module_function :version

  def authorize!
    authorizer.fetch_access_token!
  end

  module_function :authorize!

  def redis
    @redis ||= Redis::Namespace.new(
      :warmer, redis: Redis.new(url: config.redis_url)
    )
  end

  module_function :redis

  def redis_pool
    @redis_pool ||= ConnectionPool.new(config.redis_pool_options) do
      Redis::Namespace.new(
        :warmer, redis: Redis.new(url: config.redis_url)
      )
    end
  end

  module_function :redis_pool

  def compute
    @compute ||= Google::Apis::ComputeV1::ComputeService.new.tap do |compute|
      compute.authorization = authorizer
    end
  end

  module_function :compute

  def authorizer
    @authorizer ||= Google::Auth::ServiceAccountCredentials.make_creds(
      json_key_io: StringIO.new(config.google_cloud_keyfile_json),
      scope: 'https://www.googleapis.com/auth/compute'
    )
  end

  module_function :authorizer

  def pools
    # TODO: wrap this in some caching?
    redis.hgetall('poolconfigs')
  end

  module_function :pools
end
