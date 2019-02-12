# frozen_string_literal: true

require 'json'
require 'logger'
require 'securerandom'
require 'yaml'

require 'google/apis/compute_v1'
require 'libhoney'
require 'net/ssh'
require 'redis'
require 'sinatra/base'

module Warmer
  class App < Sinatra::Base
    configure(:staging, :production) do
      auth_token = ENV.fetch('AUTH_TOKEN')

      use Rack::Auth::Basic, 'Protected Area' do |_username, password|
        Rack::Utils.secure_compare(password, auth_token)
      end

      Warmer.authorize!
    end

    post '/request-instance' do
      begin
        payload = JSON.parse(request.body.read)
        ev = libhoney.event

        pool_name = matcher.match(payload)
        unless pool_name
          log.error "no matching pool found for request #{payload}"
          content_type :json
          status 404
          ev.add(
            "status": 404,
            "requested_pool_name": matcher.generate_pool_name(payload)
          )
          ev.send
          return {
            error: 'no config found for pool'
          }.to_json
        end

        instance = matcher.request_instance(pool_name)

        if instance.nil?
          log.error "no instances available in pool #{pool_name}"
          content_type :json
          status 409 # Conflict
          ev.add(
            "status": 409,
            "requested_pool_name": pool_name
          )
          ev.send
          return {
            error: 'no instance available in pool'
          }.to_json
        end
      rescue StandardError => e
        log.error e.message
        log.error e.backtrace
        status 500
        ev.add(
          "status": 500,
          "error": e.message
        )
        ev.send
        return {
          error: e.message
        }.to_json
      end

      instance_data = JSON.parse(instance)
      log.info "returning instance #{instance_data['name']}, formerly in pool #{pool_name}"
      ev.add(
        "status": 200,
        "requested_pool_name": pool_name
      )
      ev.send
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
        status 200
      else
        status 404
      end
    end

    get '/' do
      ev = libhoney.event
      ev.add(
        "status": 200,
        "env": 'TEST'
      )
      ev.send
      return 'warmer no warming'
    end

    private def libhoney
      @libhoney ||= build_libhoney
    end

    private def matcher
      @matcher ||= Warmer::Matcher.new
    end

    private def log
      @log ||= Logger.new($stdout).tap do |l|
        l.level = Logger::INFO
      end
    end

    private def build_libhoney
      Libhoney::Client.new(
        writekey: ENV['HONEYCOMB_KEY'],
        dataset: 'warmer'
      )
    end
  end
end
