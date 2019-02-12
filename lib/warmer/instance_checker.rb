# frozen_string_literal: true

require 'json'

require 'google/apis/compute_v1'
require 'net/ssh'

module Warmer
  class InstanceChecker
    def run
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
        current_size = Warmer.redis.llen(pool[0])
        log.info "current size is #{current_size}, should be #{pool[1].to_i}"
        increase_size(pool) if current_size < pool[1].to_i
      end
    end

    def clean_up_orphans(queue = 'orphaned')
      log.info "cleaning up orphan queue #{queue}"
      num_orphans = Warmer.redis.llen(queue)
      log.info "#{num_orphans} orphans to clean up..."
      num_orphans.times do
        # Using .times so that if orphans are being constantly added, this won't
        # be an infinite loop
        orphan = JSON.parse(Warmer.redis.lpop(queue))
        log.info "deleting orphaned instance #{orphan['name']} from #{orphan['zone']}"
        delete_instance(orphan['name'], orphan['zone'])
      end
    end

    private def increase_size(pool)
      size_difference = pool[1].to_i - Warmer.redis.llen(pool[0])
      log.info "increasing size of pool #{pool[0]} by #{size_difference}"
      size_difference.times do
        zone = random_zone
        new_instance_info = create_instance(pool, zone)
        Warmer.redis.rpush(pool[0], JSON.dump(new_instance_info)) unless new_instance_info.nil?
      end
    end

    private def create_instance(pool, zone, labels = { "warmth": 'warmed' })
      if pool.nil?
        log.error 'Pool configuration malformed or missing, cannot create instance'
        return nil
      end

      machine_type = Warmer.compute.get_machine_type(
        project,
        File.basename(zone),
        pool[0].split(':')[1]
      )

      network = Warmer.compute.get_network(
        project,
        'main'
      )

      subnetwork = Warmer.compute.get_subnetwork(
        project,
        region,
        'jobs-org'
      )

      tags = %w[testing org warmer]
      access_configs = []
      if /\S+:public/.match?(pool[0])
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
        ENV['SSH_KEY_PASSPHRASE'] || 'FIXME_WAT'
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
        tags: Google::Apis::ComputeV1::Tags.new(
          items: tags
        ),
        labels: labels,
        scheduling: Google::Apis::ComputeV1::Scheduling.new(
          automatic_restart: true,
          on_host_maintenance: 'MIGRATE'
        ),
        disks: [Google::Apis::ComputeV1::AttachedDisk.new(
          auto_delete: true,
          boot: true,
          initialize_params: Google::Apis::ComputeV1::AttachedDiskInitializeParams.new(
            source_image: "https://www.googleapis.com/compute/v1/projects/eco-emissary-99515/global/images/#{pool[0].split(':').first}"
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
            Google::Apis::ComputeV1::Metadata::Item.new(key: 'startup-script', value: startup_script)
          ]
        )
      )

      log.info "inserting instance #{new_instance.name} into zone #{zone}"
      instance_operation = Warmer.compute.insert_instance(
        project,
        File.basename(zone),
        new_instance
      )

      log.info "waiting for new instance #{instance_operation.name} operation to complete"
      begin
        slept = 0
        while instance_operation.status != 'DONE'
          sleep 10
          slept += 10
          instance_operation = Warmer.compute.get_zone_operation(
            project,
            File.basename(zone),
            instance_operation.name
          )
          raise Exception, 'Timeout waiting for new instance operation to complete' if slept > Warmer.config.checker_vm_creation_timeout
        end

        begin
          instance = Warmer.compute.get_instance(
            project,
            File.basename(zone),
            new_instance.name
          )

          new_instance_info = {
            name: instance.name,
            ip: instance.network_interfaces.first.network_ip,
            public_ip: instance.network_interfaces.first.access_configs&.first&.nat_ip,
            ssh_private_key: ssh_private_key,
            zone: zone
          }
          log.info "new instance #{new_instance_info[:name]} is live with ip #{new_instance_info[:ip]}"
          return new_instance_info
        rescue Google::Apis::ClientError => e
          # This should probably never happen, unless our url parsing went SUPER wonky
          log.error "error creating new instance in pool #{pool[0]}: #{e}"
          raise Exception, "Google::Apis::ClientError creating instance: #{e}"
        end
      rescue Exception => e
        log.error "Exception when creating vm, #{new_instance.name} is potentially orphaned. #{e.message}: #{e.backtrace}"
        orphaned_instance_info = {
          name: new_instance.name,
          zone: zone
        }
        Warmer.redis.rpush('orphaned', JSON.dump(orphaned_instance_info))
      end

      new_instance_info
    end

    private def get_num_warmed_instances(filter = 'labels.warmth:warmed')
      total = 0
      [
        "#{region}-a",
        "#{region}-b",
        "#{region}-c",
        "#{region}-f"
      ].each do |zone|
        instances = Warmer.compute.list_instances(
          project,
          zone,
          filter: filter
        )
        total += instances.items.size unless instances.items.nil?
      end
      total
    end

    private def get_num_redis_instances
      total = 0
      Warmer.pools.each do |pool|
        total += Warmer.redis.llen(pool[0])
      end
      total
    end

    private def random_zone
      region = Warmer.compute.get_region(
        project,
        region
      )
      region.zones.sample
    end

    private def delete_instance(name, zone)
      # Zone is passed in as a url, needs to be a string

      log.info "Deleting instance #{name} from #{zone}"
      Warmer.compute.delete_instance(
        project,
        zone.split('/').last,
        name
      )
    rescue Exception => e
      log.error "Error deleting instance #{name} from zone #{zone.split('/').last}"
      log.error "#{e.message}: #{e.backtrace}"
    end

    private def log
      Warmer.logger
    end

    private def project
      Warmer.config.google_cloud_project
    end

    private def region
      Warmer.config.google_cloud_region
    end
  end
end
