# frozen_string_literal: true

require 'json'

module Warmer
  class InstanceChecker
    def initialize(adapter)
      @adapter = adapter
    end

    def run
      if ENV.key?('DYNO')
        $stdout.sync = true
        $stderr.sync = true
        STDOUT.sync = true
        STDERR.sync = true
      end

      start_time = Time.now
      errors = 0

      log.info 'Starting the instance checker main loop'
      loop do
        check_pools!
        sleep Warmer.config.checker_pool_check_interval
      rescue StandardError => e
        log.error "#{e.message}: #{e.backtrace}"
        if Time.now - start_time > Warmer.config.checker_error_interval
          # enough time has passed since the last batch of errors, we should reset the counter
          errors = 0
          start_time = Time.now
        else
          errors += 1
          break if errors >= Warmer.config.checker_max_error_count
        end
      end

      log.error 'Too many errors - Stopped checking instance pools!'
    end

    def check_pools!
      log.info 'in the pool checker'
      # Put the cleanup step first in case the orphan threshold makes this return
      clean_up_orphans

      log.info 'checking total orphan count'
      num_warmed_instances = get_num_warmed_instances
      num_redis_instances = get_num_redis_instances

      if num_warmed_instances = num_redis_instances > Warmer.config.checker_orphan_threshold
        log.error 'too many orphaned VMs, not creating any more in case something is bork'
        return
      end

      log.info "starting check of #{Warmer.pools.size} warmed pools..."
      Warmer.pools.each do |pool|
        log.info "checking size of pool #{pool[0]}"
        current_size = Warmer.redis_pool.with { |r| r.llen(pool[0]) }
        log.info "current size is #{current_size}, should be #{pool[1].to_i}"
        increase_size(pool) if current_size < pool[1].to_i
      end
    end

    def clean_up_orphans(queue = 'orphaned')
      log.info "cleaning up orphan queue #{queue}"
      num_orphans = Warmer.redis_pool.with { |r| r.llen(queue) }
      log.info "#{num_orphans} orphans to clean up..."
      num_orphans.times do
        # Using .times so that if orphans are being constantly added, this won't
        # be an infinite loop
        orphan = JSON.parse(Warmer.redis_pool.with { |r| r.lpop(queue) })
        @adapter.delete_instance(orphan)
      end
    end

    private def increase_size(pool)
      size_difference = pool[1].to_i - (Warmer.redis_pool.with { |r| r.llen(pool[0]) })
      log.info "increasing size of pool #{pool[0]} by #{size_difference}"
      size_difference.times do
        new_instance_info = create_instance(pool)
        next if new_instance_info.nil?

        Warmer.redis_pool.with do |redis|
          redis.rpush(pool[0], JSON.dump(new_instance_info))
        end
      end
    end

    private def create_instance(pool)
      if pool.nil?
        log.error 'Pool configuration malformed or missing, cannot create instance'
        return nil
      end

      @adapter.create_instance(pool)
    rescue InstanceOrphaned => e
      log.error "#{e.message} #{e.cause.message}: #{e.cause.backtrace}"
      Warmer.redis_pool.with { |r| r.rpush('orphaned', JSON.dump(e.instance)) }
    end

    private def get_num_warmed_instances
      @adapter.list_instances.size
    end

    private def get_num_redis_instances
      total = 0
      Warmer.pools.each do |pool|
        total += (Warmer.redis_pool.with { |r| r.llen(pool[0]) })
      end
      total
    end

    private def log
      Warmer.logger
    end
  end
end
