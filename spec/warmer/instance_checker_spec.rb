# frozen_string_literal: true

require_relative '../fake_compute_service'

describe Warmer::InstanceChecker do
  let :fake_compute do
    FakeComputeService.new
  end

  before :each do
    allow(Warmer).to receive(:compute).and_return(fake_compute)
  end

  def test_create_and_verify_instance
    stub_compute!

    instance_checker = Warmer::InstanceChecker.new
    pool = Warmer.pools.first
    zone = instance_checker.send(:random_zone)
    new_instance_info = instance_checker.create_instance(pool, zone, "warmth": 'test')

    new_name = new_instance_info[:name]
    assert_not_nil(new_name)

    num = instance_checker.get_num_warmed_instances('labels.warmth:test')

    instance_checker.delete_instance(new_instance_info[:name], zone)
    sleep 200 # Deletion takes a loooooooong time. But it's either this or have really flaky tests right now.
    new_num = instance_checker.get_num_warmed_instances('labels.warmth:test')

    assert_equal(1, num)
    assert_equal(0, new_num)
  end

  def test_clean_up_orphans
    stub_compute!

    instance_checker = Warmer::InstanceChecker.new
    orphan = {
      name: 'test-orphan-name',
      zone: 'us-central1-b'
    }
    Warmer.redis.rpush('orphaned-test', JSON.dump(orphan))
    Warmer.redis.rpush('orphaned-test', JSON.dump(orphan))
    instance_checker.stubs(:delete_instance).returns(true)

    instance_checker.clean_up_orphans('orphaned-test')
    assert_equal(0, Warmer.redis.llen('orphaned-test'))

    Warmer.redis.del('orphaned-test')
  end

  def test_pool_refresh
    pools = Warmer.pools
    old_size = pools.size

    Warmer.redis.hset('poolconfigs', 'foobar', 1)
    sleep 70
    pools = Warmer.pools
    assert_equal(old_size + 1, pools.size)

    Warmer.redis.hdel('poolconfigs', 'foobar')
  end
end
