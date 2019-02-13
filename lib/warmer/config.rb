# frozen_string_literal: true

require 'hashr'
require 'travis/config'

module Warmer
  class Config < Travis::Config
    extend Hashr::Env

    def auth_tokens_array
      @auth_tokens_array ||= auth_tokens.split(/[ ,]/).map(&:strip)
    end

    def self.env_namespace
      'warmer'
    end

    define(
      auth_tokens: '',
      checker_error_interval: 60,
      checker_max_error_count: 60,
      checker_orphan_threshold: 0,
      checker_pool_check_interval: 1,
      checker_vm_creation_timeout: 90,
      google_cloud_keyfile_json: '',
      google_cloud_project: '',
      google_cloud_region: '',
      logger: {
        format_type: 'l2met',
        thread_id: true
      },
      redis_pool_options: {
        size: Integer(ENV.fetch('REDIS_POOL_OPTIONS_SIZE', '5')),
        timeout: Integer(ENV.fetch('REDIS_POOL_OPTIONS_TIMEOUT', '3'))
      },
      redis_url: ENV.fetch(
        ENV.fetch('REDIS_PROVIDER', 'REDIS_URL'), 'redis://localhost:6379/0'
      )
    )

    default(access: %i[key])
  end
end
