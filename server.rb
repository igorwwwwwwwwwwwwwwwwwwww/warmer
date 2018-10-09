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

  instances = compute.list_instance_group_manager_managed_instances(
    ENV['GOOGLE_CLOUD_PROJECT'],
    ENV['GOOGLE_CLOUD_ZONE'],
    ENV['GOOGLE_CLOUD_INSTANCE_GROUP'],
    order_by: 'creationTimestamp asc'
  )

  # if instances.managedInstances.size == 0
  #   content_type :json
  #   status 409 # Conflict
  #   return {
  #     error: 'no instance available in pool'
  #   }.to_json
  # end

  #instance = instances.managedInstances.first

  # TODO: abandon instance from group

  # content_type :json
  # {
  #   name: instance.name,
  #   ip:   instance.network_interfaces.first.network_ip
  # }.to_json
# end
