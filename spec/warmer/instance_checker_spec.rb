# frozen_string_literal: true

require_relative '../fake_compute_service'

describe Warmer::InstanceChecker do
  subject(:instance_checker) { described_class.new }

  let :fake_compute do
    FakeComputeService.new
  end

  before :each do
    allow(Warmer).to receive(:compute).and_return(fake_compute)
    Warmer.redis.hset('poolconfigs', 'foobar', 1)
  end

  after :each do
    Warmer.redis.del('orphaned-test')
    fake_compute.inserted_instances = {}
  end

  it 'can create and verify an instance' do
    pool = Warmer.pools.first
    zone = instance_checker.send(:zones).sample
    new_instance_info = instance_checker.send(:create_instance, pool, zone, warmth: 'test')

    new_name = new_instance_info[:name]
    expect(new_name).to_not be_nil

    num = instance_checker.send(:get_num_warmed_instances, 'labels.warmth:test')

    instance_checker.send(:delete_instance, new_instance_info[:name], zone)
    new_num = instance_checker.send(:get_num_warmed_instances, 'labels.warmth:test')

    expect(num).to eq(1)
    expect(new_num).to be_zero
  end

  it 'can clean up orphans' do
    orphan = {
      name: 'test-orphan-name',
      zone: 'us-central1-b'
    }
    Warmer.redis.rpush('orphaned-test', JSON.dump(orphan))
    Warmer.redis.rpush('orphaned-test', JSON.dump(orphan))
    allow(instance_checker).to receive(:delete_instance).and_return(true)

    instance_checker.clean_up_orphans('orphaned-test')
    expect(Warmer.redis.llen('orphaned-test')).to be_zero
  end
end
