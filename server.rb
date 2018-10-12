require 'sinatra'
require 'redis'
require 'yaml'
require 'json'
require 'securerandom'
require 'google/apis/compute_v1'

# https://www.rubydoc.info/github/google/google-api-ruby-client/Google/Apis/ComputeV1/ComputeService
# https://github.com/googleapis/google-auth-library-ruby

class Warmer
  def authorize!
    authorizer.fetch_access_token!
  end

  def request_instance(group_name)
    redis.lpop(group_name)
  end

  def check_pools!
    config['pools'].each do |pool|
      unless redis.llen("orphaned") > ENV['ORPHAN_THRESHOLD'].to_i
        if redis.llen(pool['group_name']) < pool['target_size']
          # TODO: eventually have this support more than just GCE
          increase_size(pool)
        end
      end
      sleep ENV['POOL_CHECK_INTERVAL'].to_i # Some amount of sleep to avoid race conditions
    end
  end

  private

  def increase_size(pool)
    size_difference = pool['target_size'] - redis.llen(pool['group_name'])
    puts "increasing size of pool #{pool['group_name']} by #{size_difference}"
    size_difference.times do
      zone = random_zone

      machine_type = compute.get_machine_type(
        ENV['GOOGLE_CLOUD_PROJECT'],
        File.basename(zone),
        pool['machine_type']
      )

      subnetwork = compute.get_subnetwork(
        ENV['GOOGLE_CLOUD_PROJECT'],
        ENV['GOOGLE_CLOUD_REGION'],
        'jobs-org'
      )

      new_instance = Google::Apis::ComputeV1::Instance.new(
        name: "travis-job-#{SecureRandom.uuid}",
        machine_type: machine_type.self_link,
        tags: Google::Apis::ComputeV1::Tags.new({
          items: ['testing', 'no-ip', 'org', 'warmer'],
        }),
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
            subnetwork: subnetwork
          )
        ],
        metadata: Google::Apis::ComputeV1::Metadata.new(
          items: [Google::Apis::ComputeV1::Metadata::Item.new(key: 'block-project-ssh-keys', value: true)]
        )
      )

      puts "inserting instance #{new_instance.name} into zone #{zone}"
      instance_operation = compute.insert_instance(
        ENV['GOOGLE_CLOUD_PROJECT'],
        File.basename(zone),
        new_instance
      )

      puts "waiting for new instance #{new_instance.name} operation to complete"
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
          if slept > ENV['VM_CREATION_TIMEOUT']
            raise Exception.new("Timeout waiting for new instance operation to complete")
          end
        end

        begin
          instance = compute.get_instance(
            ENV['GOOGLE_CLOUD_PROJECT'],
            File.basename(zone),
            new_instance.name
          )
        rescue Google::Apis::ClientError => e
          # This should probably never happen, unless our url parsing went SUPER wonky
          puts "error creating new instance in group #{pool['group_name']}"
          puts e
          raise Exception.new("Google::Apis::ClientError creating instance: #{e}")
        end

        new_instance_json = {
          name: instance.name,
          ip: instance.network_interfaces.first.network_ip
        }
        puts "new instance #{new_instance_json['name']}is live with ip #{new_instance_json['ip']}"
        redis.rpush(pool['group_name'], JSON.dump(new_instance_json))

      rescue Exception => e
        puts "Exception when creating vm, #{new_instance.name} is potentially orphaned"
        redis.rpush('orphaned', new_instance.name)
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
    @redis ||= Redis.new
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
  payload = JSON.parse(request.body.read)
  group_name = "warmer-org-d-#{payload['image_name'].split('/')[-1]}" if payload['image_name']
  group_name ||= 'warmer-org-d-travis-ci-amethyst-trusty-1512508224-986baf0'

  instance = $warmer.request_instance(group_name)

  if instance.nil?
    puts "no instances available in group #{group_name}"
    content_type :json
    status 409 # Conflict
    return {
      error: 'no instance available in pool'
    }.to_json
  end

  instance_data = JSON.parse(instance)
  puts "returning instance #{instance_data['name']}, formerly in group #{group_name}"
  content_type :json
  {
    name: instance_data['name'],
    ip:   instance_data['ip']
  }.to_json
end

Thread.new do
  loop do
    $warmer.check_pools!
  end
end
