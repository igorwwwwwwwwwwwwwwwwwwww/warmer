require 'json'
require 'redis'

$log = Logger.new(STDOUT)
$log.level = Logger::INFO

class Warmer

  # This is for testing
  attr_accessor :redis

  def authorize!
    begin
      authorizer.fetch_access_token!
    rescue TypeError => e
      $log.error "Error authorizing against Google API. Have you loaded your ENV?"
      exit
    end
  end

  private

  def redis
    @redis ||= Redis.new(:timeout => 1)
  end

  def compute
    @compute ||= Google::Apis::ComputeV1::ComputeService.new.tap do |compute|
      compute.authorization = authorizer
    end
  end

  def authorizer
    @authorizer ||= Google::Auth::ServiceAccountCredentials.make_creds(
      json_key_io: StringIO.new(ENV['GOOGLE_CLOUD_KEYFILE_JSON']),
      scope: 'https://www.googleapis.com/auth/compute'
    )
  end

  def pools
    @start_time ||= Time.now
    if Time.now - @start_time > 60 or @pools.nil?
      @pools = redis.smembers('warmerpools').map { |pool| JSON.parse(pool) }
      $log.info "Refreshing pool configs from redis"
      @start_time = Time.now
    end
    @pools
  end

end
