require 'sinatra'
require 'google/apis/compute_v1'

# https://www.rubydoc.info/github/google/google-api-ruby-client/Google/Apis/ComputeV1/ComputeService
# https://github.com/googleapis/google-auth-library-ruby

compute = Google::Apis::ComputeV1::ComputeService.new

authorizer = Google::Auth::ServiceAccountCredentials.make_creds(
  json_key_io: StringIO.new(ENV['GOOGLE_CLOUD_KEYFILE_JSON']),
  scope: 'https://www.googleapis.com/auth/compute',
)
authorizer.fetch_access_token!

compute.authorization = authorizer

# post '/request-instance' do
  # payload = JSON.parse(request.body.read)
  # payload['image']

  instances = compute.list_region_instance_group_instances(
    ENV['GOOGLE_CLOUD_PROJECT'],
    ENV['GOOGLE_CLOUD_REGION'],
    ENV['GOOGLE_CLOUD_INSTANCE_GROUP'],
    order_by: 'creationTimestamp asc'
  )

  #if instances.items.size == 0
  #   content_type :json
  #   status 409 # Conflict
  #   return {
  #     error: 'no instance available in pool'
  #   }.to_json
  #end

  instance_url = instances.items.first.instance
  split_url = instance_url.split('/')
  # THIS IS HACKY I KNOW, it is too early in the morning for regex
  # TODO some sort of sensible error handling here
  project, zone, instance_id = split_url[6], split_url[8], split_url[10]

  instance = compute.get_instance(project, zone, instance_id)

  # TODO: abandon instance from group

  abandon_request = Google::Apis::ComputeV1::RegionInstanceGroupManagersAbandonInstancesRequest.new
  abandon_request.instances = [instance_url]

  #compute.abandon_region_instance_group_manager_instance(
  #  ENV['GOOGLE_CLOUD_PROJECT'],
  #  ENV['GOOGLE_CLOUD_REGION'],
  #  ENV['GOOGLE_CLOUD_INSTANCE_GROUP'],
  #  abandon_request
  #)
  #
  # TODO - maybe put a request ID in here so we can retry removing the instance from the pool if we have to
  # because multiple workers getting the same IP seems Bad

  # content_type :json
  # {
  #   name: instance.name,
  #   ip:   instance.network_interfaces.first.network_ip
  # }.to_json
# end

# TODO remove this when we're running this for reals
exit
