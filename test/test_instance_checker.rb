# This has to come before the requires because the thread runs at the very top level
# which we might want to change at some point
ENV['UNIT_TESTS'] = 'true'

require 'test/unit'
require 'json'
require 'mocha/test_unit'
require_relative '../instance_checker'

class InstanceChecker
  public :get_num_warmed_instances, :create_instance, :delete_instance, :random_zone, :pools, :redis
end

class InstanceCheckerTest < Test::Unit::TestCase

  # TODO: if we want to test the redis methods, we should set up a repeatable way of doing that

  def test_create_and_verify_instance
    instance_checker = InstanceChecker.new
    pool = instance_checker.pools.first
    zone = instance_checker.random_zone
    new_instance_info = instance_checker.create_instance(pool, zone, {"warmth": "test"})

    # If this times out but the instance was in fact created, the cleanup won't happen
    assert_not_nil(new_instance_info[:name])

    num = instance_checker.get_num_warmed_instances("labels.warmth:test")

    instance_checker.delete_instance(zone, new_instance_info[:name])
    sleep 160 # Deletion takes a long time.

    new_num = instance_checker.get_num_warmed_instances("labels.warmth:test")
    assert_equal(1, num) # Move this down here so the deletion happens even if the creation times out
    assert_equal(0, new_num)
  end

  def test_clean_up_orphans
    instance_checker = InstanceChecker.new
    orphan = {
      name: "test-orphan-name",
      zone: "us-central1-b"
    }
    instance_checker.redis.rpush('orphaned-test', JSON.dump(orphan))
    instance_checker.redis.rpush('orphaned-test', JSON.dump(orphan))
    instance_checker.stubs(:delete_instance).returns(true)

    instance_checker.clean_up_orphans('orphaned-test')
    assert_equal(0, instance_checker.redis.llen('orphaned-test'))

    instance_checker.redis.del('orphaned-test')
  end

  # TODO test mocking out timeouts/errors from GCP

  def test_pool_refresh
    instance_checker = InstanceChecker.new
    pools = instance_checker.pools
    assert_equal(1, pools.size)

    instance_checker.redis.sadd('warmerpools', '{"foo": "bar"}')
    sleep 70
    pools = instance_checker.pools
    assert_equal(2, pools.size)

    instance_checker.redis.srem('warmerpools', '{"foo": "bar"}')
  end

end

# unset this at the end
ENV['UNIT_TESTS'] = nil
