require 'sinatra'
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

post '/request-instance' do
  payload = JSON.parse(request.body.read)
  group_name = payload['image_name'].split('/')[-1] if payload['image_name']
  group_name ||= 'warmer-org-d-travis-ci-amethyst-trusty-1512508224-986baf0'

  instances = compute.list_region_instance_group_instances(
    ENV['GOOGLE_CLOUD_PROJECT'],
    ENV['GOOGLE_CLOUD_REGION'],
    group_name,
    order_by: 'creationTimestamp asc'
  )

  if instances.items.nil?
    puts "no instances available in group #{group_name}"
    content_type :json
    status 409 # Conflict
    return {
      error: 'no instance available in pool'
    }.to_json
  end

  instance_url = instances.items.first.instance
  split_url = instance_url.split('/')
  project, zone, instance_id = split_url[6], split_url[8], split_url[10]

  begin
    instance = compute.get_instance(project, zone, instance_id)
  rescue Google::Apis::ClientError
    # This should probably never happen, unless our url parsing went SUPER wonky
    content_type :json
    status 418
    return {
      error: 'cannot get specified instance from pool'
    }.to_json
  end

  # Don't block returning the instance on having to wait to sort out the sizes, that's just silly
  Thread.new do
    # TODO: get this from config somewhere? here might be race condition dragons
    manager = compute.get_region_instance_group_manager(
      ENV['GOOGLE_CLOUD_PROJECT'],
      ENV['GOOGLE_CLOUD_REGION'],
      group_name
    )
    group_size = manager.target_size

    abandon_request = Google::Apis::ComputeV1::RegionInstanceGroupManagersAbandonInstancesRequest.new
    abandon_request.instances = [instance_url]

    begin
      puts "abandoning instance #{instance_id} from group #{group_name}"
      compute.abandon_region_instance_group_manager_instances(
        ENV['GOOGLE_CLOUD_PROJECT'],
        ENV['GOOGLE_CLOUD_REGION'],
        group_name,
        abandon_request
      )
    rescue Google::Apis::ServerError
      puts "unable to abandon instance #{instance_id} from group #{group_name}"
    end

    sleep 60
    puts "restoring group #{group_name} to size #{group_size}"
    compute.resize_region_instance_group_manager(
      ENV['GOOGLE_CLOUD_PROJECT'],
      ENV['GOOGLE_CLOUD_REGION'],
      group_name,
      group_size
    )
  end

  puts "returning instance #{instance_id}, formerly in group #{group_name}"
  content_type :json
  {
    name: instance.name,
    ip:   instance.network_interfaces.first.network_ip
  }.to_json
end
