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
    config['pools'].find do |pool|
      # we shorten an image name like
      #   https://www.googleapis.com/compute/v1/projects/eco-emissary-99515/global/images/travis-ci-garnet-trusty-1503417006
      # to simply
      #   travis-ci-garnet-trusty-1503417006

      normalized_request = {
        'image_name'   => request_body['image_name']&.split('/').last,
        'machine_type' => request_body['machine_type']&.split('/').last,
        'public_ip'    => request_body['public_ip'] || nil, # map false => nil
      }
      normalized_pool = {
        'image_name'   => pool['image_name'],
        'machine_type' => pool['machine_type'],
        'public_ip'    => pool['public_ip'] || nil,
      }
      normalized_request == normalized_pool
    end
  end

  def request_instance(group_name)
    instance = redis.lpop(group_name)
    return nil if instance.nil?

    instance_object = get_instance_object(instance)
    if instance_object.nil?
      request_instance(group_name)
      # This takes care of the "deleting from redis" cleanup that used to happen in
      # the instance checker.
    else
      label_instance(instance_object, {'warmth': 'cooled'})
      instance
    end

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

    pool = $matcher.match(payload)
    unless pool
      $log.error "no matching pool found for request #{payload}"
      content_type :json
      status 404
      return {
        error: 'no instance available in pool'
      }.to_json
    end

    group_name = pool['group_name']

    instance = $matcher.request_instance(group_name)

    if instance.nil?
      $log.error "no instances available in group #{group_name}"
      content_type :json
      status 409 # Conflict
      return {
        error: 'no instance available in pool'
      }.to_json
    end
   rescue StandardError => e
    $log.error e.message
    status 500
    return {
        error: e.message
      }.to_json
    end

  instance_data = JSON.parse(instance)
  $log.info "returning instance #{instance_data['name']}, formerly in group #{group_name}"
  content_type :json
  {
    name:      instance_data['name'],
    zone:      instance_data['zone'].split('/').last,
    ip:        instance_data['ip'],
    public_ip: instance_data['public_ip'],
    ssh_private_key: instance_data['ssh_private_key'],
  }.to_json
end
