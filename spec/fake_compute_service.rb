# frozen_string_literal: true

require 'ostruct'

class FakeComputeService
  def get_region(_proj, region)
    OpenStruct.new(
      name: region,
      zones: %w[a b c f].map { |z| "#{region}-#{z}" }
    )
  end

  def get_machine_type(_proj, zone, machine_type)
    OpenStruct.new(
      zone: zone,
      name: machine_type
    )
  end

  def get_network(_proj, name)
    OpenStruct.new(name: name)
  end

  def get_subnetwork(_proj, region, name)
    OpenStruct.new(
      region: region,
      name: name
    )
  end

  def insert_instance(_proj, zone, instance)
    inserted_instances["#{zone}:#{instance.name}"] = OpenStruct.new(
      orig: instance,
      labels: instance.labels,
      name: instance.name,
      zone: zone,
      network_interfaces: [
        OpenStruct.new(
          network_ip: '10.10.42.86',
          access_configs: [
            OpenStruct.new(nat_ip: '10.54.54.54')
          ]
        )
      ]
    )

    OpenStruct.new(
      zone: zone,
      instance: instance,
      name: 'instance-insert',
      status: 'DONE'
    )
  end

  def delete_instance(_proj, zone, name)
    inserted_instances.delete("#{zone}:#{name}")
  end

  def get_instance(_proj, zone, name)
    inserted_instances.fetch("#{zone}:#{name}")
  end

  def list_instances(_proj, zone, filter: '')
    selected = inserted_instances.to_a.select do |_, inst|
      next unless inst.zone == zone

      case filter
      when /^labels\./
        key, value = filter.sub(/^labels\./, '').split(':')
        inst.labels[key.to_sym] == value
      when /^name/
        inst.name == filter.split.last
      else
        false
      end
    end

    OpenStruct.new(items: selected)
  end

  def inserted_instances
    @inserted_instances ||= {}
  end

  attr_writer :inserted_instances
end
