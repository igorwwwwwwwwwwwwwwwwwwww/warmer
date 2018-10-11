require 'sinatra'
require 'redis'
require 'yaml'
require 'json'
require 'securerandom'
require 'google/apis/compute_v1'

# https://www.rubydoc.info/github/google/google-api-ruby-client/Google/Apis/ComputeV1/ComputeService
# https://github.com/googleapis/google-auth-library-ruby

compute = Google::Apis::ComputeV1::ComputeService.new
authorizer = Google::Auth::ServiceAccountCredentials.make_creds(
  json_key_io: StringIO.new(ENV['GOOGLE_CLOUD_KEYFILE_JSON']),
  scope: 'https://www.googleapis.com/auth/compute'
)
authorizer.fetch_access_token!
compute.authorization = authorizer

config = YAML.load(ENV['CONFIG'])

redis = Redis.new

post '/request-instance' do
  payload = JSON.parse(request.body.read)
  group_name = "warmer-org-d-#{payload['image_name'].split('/')[-1]}" if payload['image_name']
  group_name ||= 'warmer-org-d-travis-ci-amethyst-trusty-1512508224-986baf0'

  instance = redis.lpop(group_name)

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
    config['pools'].each do |pool|
      if redis.llen(pool['group_name']) < pool['target_size']
        # TODO: eventually have this support more than just GCE
        increase_size(pool)
        sleep config['pool_check_interval'] # Some amount of sleep to avoid race conditions
      end
    end
  end
end

def increase_size(pool)
  size_difference = pool['target_size'] - redis.llen(pool['group_name'])
  size_difference.each do
    new_instance = Google::Apis::ComputeV1::Instance.new(
      name: "travis-job-#{SecureRandom.uuid}",
      machine_type: pool['machine_type'],
      tags: Google::Apis::ComputeV1::Tags.new({}),
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
          subnetwork: 'jobs-org'
        )
      ],
      metadata: Google::Apis::ComputeV1::Metadata.new(
        items: [Google::Apis::ComputeV1::Metadata::Item.new(key: 'block-project-ssh-keys', value: true)]
      )
    )

    instance_operation = compute.insert_instance(
      ENV['GOOGLE_CLOUD_PROJECT'],
      random_zone,
      new_instance
    )

    # TODO: should this maybe also be threaded?
    while instance_operation.status != 'DONE'
      sleep 10
      # TODO: some sort of timeout here
    end

    instance_url = instance_operation.self_link
    split_url = instance_url.split('/')
    project, zone, instance_id = split_url[6], split_url[8], split_url[10]

    begin
      instance = compute.get_instance(project, zone, instance_id)
    rescue Google::Apis::ClientError
      # This should probably never happen, unless our url parsing went SUPER wonky
      # TODO: different error handling here?
      puts "error creating new instance in group #{pool['group_name']}"
      return
    end

    new_instance = {
      name: instance.name,
      ip: instance.network_interfaces.first.network_ip
    }

    redis.rpush(pool['group_name'], JSON.dump(new_instance))
  end
end

def random_zone
  region = compute.get_region(
    ENV['GOOGLE_CLOUD_PROJECT'],
    ENV['GOOGLE_CLOUD_REGION']
  )
  region.zones.sample
end
