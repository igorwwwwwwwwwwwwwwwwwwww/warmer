# frozen_string_literal: true

require 'google/apis/compute_v1'
require 'net/ssh'

module Warmer
  module Adapter
    # Adapter for creating warmed instances on Google Compute Engine.
    class Google
      def initialize(config, compute: nil)
        @config = config
        @project = config.google_cloud_project
        @region = config.google_cloud_region

        unless compute
          @authorizer = ::Google::Auth::ServiceAccountCredentials.make_creds(
            json_key_io: StringIO.new(config.google_cloud_keyfile_json),
            scope: 'https://www.googleapis.com/auth/compute'
          )

          compute = ::Google::Apis::ComputeV1::ComputeService.new
          compute.authorization = @authorizer
        end
        @compute = compute
      end

      def authorize
        @authorizer.fetch_access_token!
      end

      def get_instance(info)
        name = info.fetch('name')
        zone = info.fetch('zone')

        @compute.get_instance(
          @project,
          File.basename(zone),
          name
        )
      rescue StandardError
        nil
      end

      def create_instance(pool)
        zone = zones.sample

        machine_type = @compute.get_machine_type(
          @project,
          File.basename(zone),
          pool[0].split(':')[1]
        )

        network = @compute.get_network(@project, 'main')
        subnetwork = @compute.get_subnetwork(
          @project,
          @region,
          'jobs-org'
        )

        tags = %w[testing org warmer]
        access_configs = []
        if /\S+:public/.match?(pool[0])
          access_configs << ::Google::Apis::ComputeV1::AccessConfig.new(
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

        source_image = "https://www.googleapis.com/compute/v1/projects/eco-emissary-99515/global/images/#{pool[0].split(':').first}"

        new_instance = ::Google::Apis::ComputeV1::Instance.new(
          name: "travis-job-#{SecureRandom.uuid}",
          machine_type: machine_type.self_link,
          tags: ::Google::Apis::ComputeV1::Tags.new(
            items: tags
          ),
          labels: { warmth: 'warmed' },
          scheduling: ::Google::Apis::ComputeV1::Scheduling.new(
            automatic_restart: true,
            on_host_maintenance: 'MIGRATE'
          ),
          disks: [::Google::Apis::ComputeV1::AttachedDisk.new(
            auto_delete: true,
            boot: true,
            initialize_params: ::Google::Apis::ComputeV1::AttachedDiskInitializeParams.new(source_image: source_image)
          )],
          network_interfaces: [
            ::Google::Apis::ComputeV1::NetworkInterface.new(
              network: network.self_link,
              subnetwork: subnetwork.self_link,
              access_configs: access_configs
            )
          ],
          metadata: ::Google::Apis::ComputeV1::Metadata.new(
            items: [
              ::Google::Apis::ComputeV1::Metadata::Item.new(key: 'block-project-ssh-keys', value: true),
              ::Google::Apis::ComputeV1::Metadata::Item.new(key: 'startup-script', value: startup_script)
            ]
          )
        )

        log.info "inserting instance #{new_instance.name} into zone #{zone}"
        instance_operation = @compute.insert_instance(
          @project,
          File.basename(zone),
          new_instance
        )

        log.info "waiting for new instance #{instance_operation.name} operation to complete"
        begin
          slept = 0
          while instance_operation.status != 'DONE'
            sleep 10
            slept += 10
            instance_operation = @compute.get_zone_operation(
              @project,
              File.basename(zone),
              instance_operation.name
            )
            raise Exception, 'Timeout waiting for new instance operation to complete' if slept > @config.checker_vm_creation_timeout
          end

          begin
            instance = @compute.get_instance(
              @project,
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
          rescue ::Google::Apis::ClientError => e
            # This should probably never happen, unless our url parsing went SUPER wonky
            log.error "error creating new instance in pool #{pool[0]}: #{e}"
            raise Exception, "Google::Apis::ClientError creating instance: #{e}"
          end
        rescue StandardError
          orphaned_instance = {
            name: new_instance.name,
            zone: zone
          }
          raise Warmer::InstanceOrphaned, "Exception when creating vm, #{new_instance.name} is potentially orphaned.", orphaned_instance
        end

        new_instance_info
      end

      def label_instance(instance, labels)
        label_request = ::Google::Apis::ComputeV1::InstancesSetLabelsRequest.new
        label_request.label_fingerprint = instance.label_fingerprint
        label_request.labels = labels

        @compute.set_instance_labels(
          @project,
          instance.zone.split('/').last,
          instance.name,
          label_request
        )
      end

      def list_instances
        [
          "#{@region}-a",
          "#{@region}-b",
          "#{@region}-c",
          "#{@region}-f"
        ].flat_map do |zone|
          instances = @compute.list_instances(
            @project,
            zone,
            filter: 'labels.warmth:warmed'
          )
          instances.items || []
        end
      end

      def delete_instance(instance)
        name = instance['name']
        zone = instance['zone'].to_s.split('/').last

        log.info "deleting orphaned instance #{name} from #{zone}"

        @compute.delete_instance(
          @project,
          zone,
          name
        )
      rescue StandardError => e
        log.error "Error deleting instance #{name} from zone #{zone}"
        log.error "#{e.message}: #{e.backtrace}"
      end

      private def log
        Warmer.logger
      end

      private def zones
        @zones ||= @compute.get_region(@project, @region).zones
      end
    end
  end
end
