require 'google/apis/compute_v1'
require 'json'
require 'logger'
require 'redis'
require 'set'

log = Logger.new(STDOUT)
log.level = Logger::INFO

error_interval = ENV['ERROR_INTERVAL']&.to_i || 60
max_error_count = ENV['MAX_ERROR_COUNT']&.to_i || 60

authorizer = Google::Auth::ServiceAccountCredentials.make_creds(
    json_key_io: StringIO.new(ENV['GOOGLE_CLOUD_KEYFILE_JSON']),
    scope: 'https://www.googleapis.com/auth/compute')
compute = Google::Apis::ComputeV1::ComputeService.new.tap do |compute|
    compute.authorization = authorizer
end
config = YAML.load(ENV['CONFIG'])

start_time = Time.now
errors = 0
loop do
    begin
      redis = Redis.new()
      tracked_instances = Set.new()

      # We first check if all the currently tracked instances still exist
      pools = config['pools'].map { |a| a['group_name'] }
      pools.each do |p|
          len = redis.llen(p)
          redis.lrange(p, 0, len).each do |instance|
            name = JSON.parse(instance)['name']
            zone = JSON.parse(instance)['zone']
            begin
              instance = compute.get_instance(
                  ENV['GOOGLE_CLOUD_PROJECT'],
                  File.basename(zone),
                  name)
              tracked_instances.add(instance.name)
            rescue StandardError => e
              log.info "Couldn't get instance #{name}: #{e.message}"
              # instance is no longer there, remove it from Redis
              log.info "Removing #{name} from redis since it is unreachable"
              redis.lrem(p, 0, instance)
            end
          end
      end
      redis.close

      # Next, now that we have all the instances tracked across all pools, we go
      # through the 'warmer' instances in GCE to find ones that aren't tracked
      # in redis. This happens separately because GCE doesn't have the same
      # concept of 'pools' that redis does.
      zones = [
          "#{ENV['GOOGLE_CLOUD_REGION']}-a",
          "#{ENV['GOOGLE_CLOUD_REGION']}-b",
          "#{ENV['GOOGLE_CLOUD_REGION']}-c",
          "#{ENV['GOOGLE_CLOUD_REGION']}-f"]
      zones.each do |zone|
        instances = compute.list_instances(
            ENV['GOOGLE_CLOUD_PROJECT'], zone,
            filter: "labels.warmth:warmed")
        unless instances.items.nil?
          instances.items.each do |instance|
            unless tracked_instances.include?(instance.name)
                log.info "Removing #{instance.name} from GCE since it isn't tracked in redis"
                compute.delete_instance(
                  ENV['GOOGLE_CLOUD_PROJECT'], zone, instance.name
                )
            end
          end
        end
      end

      sleep ENV['INSTANCE_CHECK_INTERVAL'].to_i
    rescue StandardError => e
      log.error "#{e.message}: #{e.backtrace}"
      if Time.now - start_time > error_interval
        # enough time has passed since the last batch of errors, we should reset the counter
        errors = 0
        start_time = Time.now
      else
        errors += 1
        break if errors >= max_error_count
      end
  end
end
log.error "Too many errors - Stopped checking instance pools!"
