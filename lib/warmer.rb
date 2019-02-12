# frozen_string_literal: true

require 'google/apis/compute_v1'
require 'redis'

module Warmer
  autoload :App, 'warmer/app'
  autoload :Matcher, 'warmer/matcher'
  autoload :InstanceChecker, 'warmer/instance_checker'

  def authorize!
    authorizer.fetch_access_token!
  end

  module_function :authorize!

  def redis
    @redis ||= Redis.new(timeout: 1)
  end

  module_function :redis

  def compute
    @compute ||= Google::Apis::ComputeV1::ComputeService.new.tap do |compute|
      compute.authorization = authorizer
    end
  end

  module_function :compute

  def authorizer
    @authorizer ||= Google::Auth::ServiceAccountCredentials.make_creds(
      json_key_io: StringIO.new(ENV.fetch('GOOGLE_CLOUD_KEYFILE_JSON')),
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
