# frozen_string_literal: true

require_relative 'travis'

require 'connection_pool'
require 'redis-namespace'
require 'travis/logger'

require 'warmer/error'

module Warmer
  autoload :Adapter, 'warmer/adapter'
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
    adapter.authorize
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

  def adapter
    # TODO: which adapter should be determined by config
    @adapter ||= Warmer::Adapter::Google.new(config)
  end

  module_function :adapter

  def pools
    # TODO: wrap this in some caching?
    redis.hgetall('poolconfigs')
  end

  module_function :pools
end
