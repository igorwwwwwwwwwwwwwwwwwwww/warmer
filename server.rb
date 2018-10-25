require 'google/apis/compute_v1'
require 'json'
require 'logger'
require 'net/ssh'
require 'redis'
require 'securerandom'
require 'sinatra'
require 'yaml'

# https://www.rubydoc.info/github/google/google-api-ruby-client/Google/Apis/ComputeV1/ComputeService
# https://github.com/googleapis/google-auth-library-ruby

$stdout.sync = true
$stderr.sync = true

$log = Logger.new(STDOUT)
$log.level = Logger::WARN

error_interval = ENV['ERROR_INTERVAL']&.to_i || 60
max_error_count = ENV['MAX_ERROR_COUNT']&.to_i || 60

class Warmer
  def authorize!
    authorizer.fetch_access_token!
  end

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
    redis.lpop(group_name)
  end

  def check_pools!
    config['pools'].each do |pool|
      $log.info "checking size of pool #{pool}"
      if redis.llen("orphaned") <= ENV['ORPHAN_THRESHOLD'].to_i
        if redis.llen(pool['group_name']) < pool['target_size']
          # TODO: eventually have this support more than just GCE
          increase_size(pool)
        end
      else
        $log.error "too many orphaned VMs, not creating any more in case something is bork"
      end
    end
  end

  private

  def increase_size(pool)
    size_difference = pool['target_size'] - redis.llen(pool['group_name'])
    $log.info "increasing size of pool #{pool['group_name']} by #{size_difference}"
    size_difference.times do
      zone = random_zone

      machine_type = compute.get_machine_type(
        ENV['GOOGLE_CLOUD_PROJECT'],
        File.basename(zone),
        pool['machine_type']
      )

      network = compute.get_network(
        ENV['GOOGLE_CLOUD_PROJECT'],
        'main'
      )

      subnetwork = compute.get_subnetwork(
        ENV['GOOGLE_CLOUD_PROJECT'],
        ENV['GOOGLE_CLOUD_REGION'],
        'jobs-org'
      )

      tags = ['testing', 'org', 'warmer']
      access_configs = []
      if pool['public_ip']
        access_configs << Google::Apis::ComputeV1::AccessConfig.new(
          name: 'AccessConfig brought to you by warmer',
          type: 'ONE_TO_ONE_NAT'
        )
      else
        tags << 'no-ip'
      end

      ssh_key = OpenSSL::PKey::RSA.new(2048)
      ssh_public_key = ssh_key.public_key
      ssh_private_key = ssh_key.export(
        OpenSSL::Cipher::AES.new(256, :CBC),
        ENV['SSH_KEY_PASSPHRASE']
      )

      startup_script = <<~RUBYEOF
      cat > ~travis/.ssh/authorized_keys <<EOF
        #{ssh_public_key.ssh_type} #{[ssh_public_key.to_blob].pack('m0')}
      EOF
      chown -R travis:travis ~travis/.ssh/
      RUBYEOF

      new_instance = Google::Apis::ComputeV1::Instance.new(
        name: "travis-job-#{SecureRandom.uuid}",
        machine_type: machine_type.self_link,
        tags: Google::Apis::ComputeV1::Tags.new({
          items: tags,
        }),
        labels: {"warmth": "warmed"},
        scheduling: Google::Apis::ComputeV1::Scheduling.new(
          automatic_restart: true,
          on_host_maintenance: 'MIGRATE'
        ),
        disks: [Google::Apis::ComputeV1::AttachedDisk.new(
          auto_delete: true,
          boot: true,
          initialize_params: Google::Apis::ComputeV1::AttachedDiskInitializeParams.new(
            source_image: "https://www.googleapis.com/compute/v1/projects/eco-emissary-99515/global/images/#{pool['image_name']}"
          )
        )],
        network_interfaces: [
          Google::Apis::ComputeV1::NetworkInterface.new(
            network: network.self_link,
            subnetwork: subnetwork.self_link,
            access_configs: access_configs
          )
        ],
        metadata: Google::Apis::ComputeV1::Metadata.new(
          items: [
            Google::Apis::ComputeV1::Metadata::Item.new(key: 'block-project-ssh-keys', value: true),
            Google::Apis::ComputeV1::Metadata::Item.new(key: 'startup-script', value: startup_script),
          ]
        )
      )

      $log.info "inserting instance #{new_instance.name} into zone #{zone}"
      instance_operation = compute.insert_instance(
        ENV['GOOGLE_CLOUD_PROJECT'],
        File.basename(zone),
        new_instance
      )

      $log.info "waiting for new instance #{new_instance.name} operation to complete"
      begin
        slept = 0
        while instance_operation.status != 'DONE'
          sleep 10
          slept += 10
          instance_operation = compute.get_zone_operation(
            ENV['GOOGLE_CLOUD_PROJECT'],
            File.basename(zone),
            instance_operation.name
          )
          if slept > ENV['VM_CREATION_TIMEOUT'].to_i
            raise Exception.new("Timeout waiting for new instance operation to complete")
          end
        end

        begin
          instance = compute.get_instance(
            ENV['GOOGLE_CLOUD_PROJECT'],
            File.basename(zone),
            new_instance.name
          )

          new_instance_info = {
            name: instance.name,
            ip: instance.network_interfaces.first.network_ip,
            public_ip: instance.network_interfaces.first.access_configs&.first&.nat_ip,
            ssh_private_key: ssh_private_key,
            zone: zone,
          }
          $log.info "new instance #{new_instance_info[:name]} is live with ip #{new_instance_info[:ip]}"
          redis.rpush(pool['group_name'], JSON.dump(new_instance_info))
        rescue Google::Apis::ClientError => e
          # This should probably never happen, unless our url parsing went SUPER wonky
          $log.error "error creating new instance in group #{pool['group_name']}: #{e}"
          raise Exception.new("Google::Apis::ClientError creating instance: #{e}")
        end

      rescue Exception => e
        $log.error "Exception when creating vm, #{new_instance.name} is potentially orphaned. #{e.message}: #{e.backtrace}"
        redis.rpush('orphaned', {name: new_instance.name, zone: zone})
      end

    end # times
  end # method

  def random_zone
    region = compute.get_region(
      ENV['GOOGLE_CLOUD_PROJECT'],
      ENV['GOOGLE_CLOUD_REGION']
    )
    region.zones.sample
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

  def config
    @config ||= YAML.load(ENV['CONFIG'])
  end

  def redis
    @redis ||= Redis.new(:timeout => 1)
  end
end

$warmer = Warmer.new
$warmer.authorize!

if ENV['AUTH_TOKEN']
  use Rack::Auth::Basic, "Protected Area" do |username, password|
    Rack::Utils.secure_compare(password, ENV['AUTH_TOKEN'])
  end
end

post '/request-instance' do
  begin
    payload = JSON.parse(request.body.read)

    pool = $warmer.match(payload)
    unless pool
      $log.error "no matching pool found for request #{payload}"
      content_type :json
      status 404
      return {
        error: 'no instance available in pool'
      }.to_json
    end

    group_name = pool['group_name']

    instance = $warmer.request_instance(group_name)

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
    ip:        instance_data['ip'],
    public_ip: instance_data['public_ip'],
    ssh_private_key: instance_data['ssh_private_key'],
  }.to_json
end

Thread.new do
  start_time = Time.now
  errors = 0
  loop do
    begin
      $warmer.check_pools!
      sleep ENV['POOL_CHECK_INTERVAL'].to_i # Some amount of sleep to avoid race conditions
    rescue StandardError => e
      $log.error "#{e.message}: #{e.backtrace}"
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
  $log.error "Too many errors - Stopped checking instance pools!"
end
