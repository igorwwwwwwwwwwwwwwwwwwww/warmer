# frozen_string_literal: true

require 'json'
require 'securerandom'
require 'yaml'

require 'google/apis/compute_v1'
require 'net/ssh'
require 'redis'
require 'sinatra/base'

module Warmer
  class App < Sinatra::Base
    configure(:staging, :production) do
      require 'rack/ssl'
      use Rack::SSL

      require 'honeycomb-beeline'
      require 'rack/honeycomb/middleware'
      use Rack::Honeycomb::Middleware, is_sinatra: true

      use Rack::Auth::Basic, 'Protected Area' do |_, password|
        Warmer.config.auth_tokens_array.any? do |auth_token|
          Rack::Utils.secure_compare(password, auth_token)
        end
      end

      $stdout.sync = true
      $stderr.sync = true
      STDOUT.sync = true
      STDERR.sync = true

      Warmer.authorize!
    end

    post '/request-instance' do
      begin
        payload = JSON.parse(request.body.read)

        pool_name = matcher.match(payload)
        unless pool_name
          log.error "no matching pool found for request #{payload}"
          content_type :json
          status 404
          return {
            error: 'no config found for pool'
          }.to_json
        end

        instance = matcher.request_instance(pool_name)

        if instance.nil?
          log.error "no instances available in pool #{pool_name}"
          content_type :json
          status 409 # Conflict
          return {
            error: 'no instance available in pool'
          }.to_json
        end
      rescue StandardError => e
        log.error e.message
        log.error e.backtrace
        status 500
        return {
          error: e.message
        }.to_json
      end

      instance_data = JSON.parse(instance)
      log.info "returning instance #{instance_data['name']}, formerly in pool #{pool_name}"
      content_type :json
      {
        name: instance_data['name'],
        zone: instance_data['zone'].split('/').last,
        ip: instance_data['ip'],
        public_ip: instance_data['public_ip'],
        ssh_private_key: instance_data['ssh_private_key']
      }.to_json
    end

    get '/pool-configs/?:pool_name?' do
      pool_config_json = matcher.get_config(params[:pool_name])
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
      log.info "updating config for pool #{params[:pool_name]}"
      # Pool name must be at least image-name:machine-type, target_size must be int
      if params[:pool_name].split(':').size < 2
        status 400
        return {
          error: 'Pool name must be of format image_name:machine_type(:public_ip)'
        }.to_json
      end
      unless pool_size = begin
                           Integer(params[:target_size])
                         rescue StandardError
                           false
                         end
        status 400
        return {
          error: 'Target pool size must be an integer'
        }.to_json
      end
      begin
        matcher.set_config(params[:pool_name], pool_size)
        status 200
      rescue Exception => e
        log.error e.message
        log.error e.backtrace
        status 500
        return {
          error: e.message
        }.to_json
      end
    end

    delete '/pool-configs/:pool_name' do
      if matcher.has_pool? params[:pool_name]
        matcher.delete_config(params[:pool_name])
        status 204
      else
        status 404
      end
    end

    get '/' do
      content_type :text
      "warmer no warming\n"
    end

    private def matcher
      @matcher ||= Warmer::Matcher.new
    end

    private def log
      Warmer.logger
    end
  end
end
