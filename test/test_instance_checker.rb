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

  def test_get_num_warmed_instances
    instance_checker = InstanceChecker.new
    num = instance_checker.get_num_warmed_instances("labels.cats:aregreat")
    assert_equal(1, num)
  end

  # TODO: if we want to test the redis methods, we should set up a repeatable way of doing that

  def test_create_and_verify_instance
    instance_checker = InstanceChecker.new
    pool = instance_checker.pools.first
    zone = instance_checker.random_zone
    new_instance_info = instance_checker.create_instance(pool, zone)

    assert_not_nil(new_instance_info[:name])

    instance_checker.delete_instance(zone, new_instance_info[:name])
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

  # TODO test orphan detection/cleanup/etc

  # TODO test mocking out timeouts/errors from GCP

end

# unset this at the end
ENV['UNIT_TESTS'] = nil
