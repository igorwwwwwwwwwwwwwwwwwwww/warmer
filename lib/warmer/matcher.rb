require 'google/apis/compute_v1'
require 'json'
require 'logger'
require 'net/ssh'
require 'securerandom'
require 'sinatra'
require 'yaml'
require 'libhoney'

require 'warmer'

module Warmer
  class Matcher
    def match(request_body)
      # Takes a request containing image name (as url), machine type (as url), and public_ip as boolean
      # and returns the pool name IN REDIS that matches it.
      # If no matching pool exists in redis, returns nil.

      # we shorten an image name like
      #   https://www.googleapis.com/compute/v1/projects/eco-emissary-99515/global/images/travis-ci-garnet-trusty-1503417006
      # to simply
      #   travis-ci-garnet-trusty-1503417006
      pool_name = generate_pool_name(request_body)
      log.info "looking for pool named #{pool_name} in config based on request #{request_body}"

      if has_pool?(pool_name)
        return pool_name
      else
        return nil
      end
    end

    def generate_pool_name(request_body)
      request_image_name = request_body['image_name']&.split('/').last
      request_machine_type = request_body['machine_type']&.split('/').last
      request_public_ip = request_body['public_ip'] == "true" || false

      pool_name = "#{request_image_name}:#{request_machine_type}"
      pool_name += ":public" if request_public_ip

      pool_name
    end

    def request_instance(pool_name)
      instance = Warmer.redis.lpop(pool_name)
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
        Warmer.pools
      else
        if has_pool?(pool_name)
          { pool_name => Warmer.pools[pool_name] }
        else
          nil
        end
      end
    end

    def has_pool?(pool_name)
      Warmer.pools.has_key?(pool_name)
    end

    def set_config(pool_name, target_size)
      Warmer.redis.hset('poolconfigs', pool_name, target_size)
    end

    def delete_config(pool_name)
      Warmer.redis.hdel('poolconfigs', pool_name)
    end

    private def get_instance_object(instance)
      begin
        name = JSON.parse(instance)['name']
        zone = JSON.parse(instance)['zone']
        instance_object = Warmer.compute.get_instance(
          ENV['GOOGLE_CLOUD_PROJECT'],
          File.basename(zone),
          name)
        instance_object
      rescue StandardError => e
        nil
      end
    end

    private def label_instance(instance_object, labels={})
      label_request = Google::Apis::ComputeV1::InstancesSetLabelsRequest.new
      label_request.label_fingerprint = instance_object.label_fingerprint
      label_request.labels = labels

      Warmer.compute.set_instance_labels(
        ENV['GOOGLE_CLOUD_PROJECT'],
        instance_object.zone.split('/').last,
        instance_object.name,
        label_request
      )
    end

    private def log
      @log ||= Logger.new($stdout).tap do |l|
        l.level = Logger::INFO
      end
    end
  end
end
