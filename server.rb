require 'google/apis/compute_v1'
require 'json'
require 'logger'
require 'net/ssh'
require 'redis'
require 'securerandom'
require 'sinatra'
require 'yaml'
require_relative 'warmer'

# https://www.rubydoc.info/github/google/google-api-ruby-client/Google/Apis/ComputeV1/ComputeService
# https://github.com/googleapis/google-auth-library-ruby

$stdout.sync = true
$stderr.sync = true

$log = Logger.new(STDOUT)
$log.level = Logger::INFO

error_interval = ENV['ERROR_INTERVAL']&.to_i || 60
max_error_count = ENV['MAX_ERROR_COUNT']&.to_i || 60

class Matcher < Warmer

  def match(request_body)
    # Takes a request containing image name (as url), machine type (as url), and public_ip as boolean
    # and returns the pool name IN REDIS that matches it.
    # If no matching pool exists in redis, returns nil.

    # we shorten an image name like
    #   https://www.googleapis.com/compute/v1/projects/eco-emissary-99515/global/images/travis-ci-garnet-trusty-1503417006
    # to simply
    #   travis-ci-garnet-trusty-1503417006
    request_image_name = request_body['image_name']&.split('/').last
    request_machine_type = request_body['machine_type']&.split('/').last
    request_public_ip = request_body['public_ip'] || nil, # map false => nil

    pool_name = "#{request_image_name}:#{request_machine_type}"
    pool_name += ":public" if request_public_ip

    $log.info "looking for pool named #{pool_name} in config based on request #{request_body}"

    if pools.has_key? pool_name
      return pool_name
    else
      return nil
    end
  end

  def request_instance(pool_name)
    instance = redis.lpop(pool_name)
    return nil if instance.nil?

    instance_object = get_instance_object(instance)
    if instance_object.nil?
      request_instance(pool_name)
      # This takes care of the "deleting from redis" cleanup that used to happen in
      # the instance checker.
    else
      label_instance(instance_object, {'warmth': 'cooled'})
      instance
    end
  end

  def get_config(pool_name=nil)
    if pool_name.nil?
      pools
    else
      if has_pool? pool_name
        {pool_name => pools[pool_name]}
      else
        nil
      end
    end
  end

  def has_pool?(pool_name)
    pools = redis.hgetall('poolconfigs')
    return pools.has_key? pool_name
  end

  def set_config(pool_name, target_size)
    redis.hset('poolconfigs', pool_name, target_size)
  end

  def delete_config(pool_name)
    redis.hdel('poolconfigs', pool_name)
  end

  private

  def get_instance_object(instance)
    begin
      name = JSON.parse(instance)['name']
      zone = JSON.parse(instance)['zone']
      instance_object = compute.get_instance(
        ENV['GOOGLE_CLOUD_PROJECT'],
        File.basename(zone),
        name)
      instance_object
    rescue StandardError => e
      nil
    end
  end

  def label_instance(instance_object, labels={})
    label_request = Google::Apis::ComputeV1::InstancesSetLabelsRequest.new
    label_request.label_fingerprint = instance_object.label_fingerprint
    label_request.labels = labels

    compute.set_instance_labels(
      ENV['GOOGLE_CLOUD_PROJECT'],
      instance_object.zone.split('/').last,
      instance_object.name,
      label_request
    )
  end

end

$matcher = Matcher.new
$matcher.authorize!

if ENV['AUTH_TOKEN']
  use Rack::Auth::Basic, "Protected Area" do |username, password|
    Rack::Utils.secure_compare(password, ENV['AUTH_TOKEN'])
  end
end

post '/request-instance' do
  begin
    payload = JSON.parse(request.body.read)

    pool_name = $matcher.match(payload)
    unless pool_name
      $log.error "no matching pool found for request #{payload}"
      content_type :json
      status 404
      return {
        error: 'no config found for pool'
      }.to_json
    end

    instance = $matcher.request_instance(pool_name)

    if instance.nil?
      $log.error "no instances available in pool #{pool_name}"
      content_type :json
      status 409 # Conflict
      return {
        error: 'no instance available in pool'
      }.to_json
    end
  rescue StandardError => e
    $log.error e.message
    $log.error e.backtrace
    status 500
    return {
      error: e.message
    }.to_json
  end

  instance_data = JSON.parse(instance)
  $log.info "returning instance #{instance_data['name']}, formerly in pool #{pool_name}"
  content_type :json
  {
    name:      instance_data['name'],
    zone:      instance_data['zone'].split('/').last,
    ip:        instance_data['ip'],
    public_ip: instance_data['public_ip'],
    ssh_private_key: instance_data['ssh_private_key'],
  }.to_json
end


get '/pool-configs/?:pool_name?' do
  pool_config_json = $matcher.get_config(params[:pool_name])
  if pool_config_json.nil?
    content_type :json
    status 404
    return {}
  end
  content_type :json
  status 200
  pool_config_json.to_json
end

post '/pool-configs/:pool_name/:target_size' do
  puts "updating config for pool #{params[:pool_name]}"
  # Pool name must be at least image-name:machine-type, target_size must be int
  if params[:pool_name].split(':').size < 2
    status 400
    return {
      error: "Pool name must be of format image_name:machine_type(:public_ip)"
    }.to_json
  end
  if not pool_size = Integer(params[:target_size]) rescue false
    status 400
    return {
      error: "Target pool size must be an integer"
    }.to_json
  end
  begin
    $matcher.set_config(params[:pool_name], pool_size)
    status 200
  rescue Exception => e
    $log.error e.message
    $log.error e.backtrace
    status 500
    return {
      error: e.message
    }.to_json
  end
end

delete '/pool-configs/:pool_name' do
  if $matcher.has_pool? params[:pool_name]
    $matcher.delete_config(params[:pool_name])
    status 200
  else
    status 404
  end
end

get '/' do
  return "warmer no warming"
end
