require 'simplecov'

require 'json'

require 'minitest/autorun'
require 'minitest/hooks'
require 'mocha/minitest'

libdir = File.expand_path('../lib', __dir__)
$LOAD_PATH.unshift(libdir) unless $LOAD_PATH.include?(libdir)

require 'warmer'

class InstanceCheckerTest < Minitest::Test
  include Minitest::Hooks

  def after_all
    super
    clean_up_test_instances
  end

  def test_create_and_verify_instance
    instance_checker = Warmer::InstanceChecker.new
    pool = Warmer.pools.first
    zone = instance_checker.send(:random_zone)
    new_instance_info = instance_checker.create_instance(pool, zone, {"warmth": "test"})

    new_name = new_instance_info[:name]
    assert_not_nil(new_name)

    num = instance_checker.get_num_warmed_instances("labels.warmth:test")

    instance_checker.delete_instance(new_instance_info[:name], zone)
    sleep 200 # Deletion takes a loooooooong time. But it's either this or have really flaky tests right now.
    new_num = instance_checker.get_num_warmed_instances("labels.warmth:test")

    assert_equal(1, num)
    assert_equal(0, new_num)
  end

  def test_clean_up_orphans
    instance_checker = Warmer::InstanceChecker.new
    orphan = {
      name: "test-orphan-name",
      zone: "us-central1-b"
    }
    Warmer.redis.rpush('orphaned-test', JSON.dump(orphan))
    Warmer.redis.rpush('orphaned-test', JSON.dump(orphan))
    instance_checker.stubs(:delete_instance).returns(true)

    instance_checker.clean_up_orphans('orphaned-test')
    assert_equal(0, Warmer.redis.llen('orphaned-test'))

    Warmer.redis.del('orphaned-test')
  end

  # TODO test mocking out timeouts/errors from GCP

  def test_pool_refresh
    instance_checker = Warmer::InstanceChecker.new
    pools = Warmer.pools
    old_size = pools.size

    Warmer.redis.hset('poolconfigs', "foobar", 1)
    sleep 70
    pools = Warmer.pools
    assert_equal(old_size + 1, pools.size)

    Warmer.redis.hdel('poolconfigs', "foobar")
  end

  private def clean_up_test_instances
    instance_checker = Warmer::InstanceChecker.new
    zones = [
          "#{ENV['GOOGLE_CLOUD_REGION']}-a",
          "#{ENV['GOOGLE_CLOUD_REGION']}-b",
          "#{ENV['GOOGLE_CLOUD_REGION']}-c",
          "#{ENV['GOOGLE_CLOUD_REGION']}-f"]
    zones.each do |zone|
      instances = Warmer.compute.list_instances(
          ENV['GOOGLE_CLOUD_PROJECT'], zone,
          filter: "labels.warmth:test")
      unless instances.items.nil?
        instances.items.each do |instance|
          instance_checker.delete_instance(instance.name, zone)
        end
      end
    end
  end
end
