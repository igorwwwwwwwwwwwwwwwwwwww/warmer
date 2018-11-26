require 'test/unit'
require 'json'
require 'mocha/test_unit'
require_relative '../server'

class Matcher
  public :get_instance_object, :label_instance
end

class ServerTest < Test::Unit::TestCase

  def setup
    @request_body = JSON.parse("{\"image_name\": \"https://www.googleapis.com/compute/v1/projects/eco-emissary-99515/global/images/travis-ci-garnet-trusty-1503417006\",
      \"machine_type\": \"n1-standard-1\",
      \"public_ip\": \"123.45.67.89\"}")

    @instance = "{\"name\": \"unit-test-warmer-dont-kill-me-plz\", \"zone\": \"us-central1-c\"}"
    @bad_instance = "{\"name\": \"im-not-real\", \"zone\": \"us-central1-c\"}"
  end

  def test_match
    matcher = Matcher.new
    assert(true, matcher.match(@request_body))
  end

  def test_request_instance_empty_redis
    matcher = Matcher.new
    instance = matcher.request_instance('fake_group')
    assert_equal(nil, instance)
  end

  def test_request_instance
    fake_redis = mock()
    fake_redis.stubs(:lpop).returns("cool_instance")
    matcher = Matcher.new
    matcher.stubs(:get_instance_object).returns(true)
    matcher.stubs(:label_instance).returns(true)
    matcher.redis = fake_redis

    instance = matcher.request_instance('fake_group')
    assert_equal("cool_instance", instance)

  end

  def test_request_instance_doesnt_exist
    fake_redis = mock()
    fake_redis.stubs(:lpop).returns("cool_instance", "better_instance")
    matcher = Matcher.new
    matcher.stubs(:get_instance_object).returns(nil, true)
    matcher.stubs(:label_instance).returns(true)
    matcher.redis = fake_redis

    instance = matcher.request_instance('fake_group')
    assert_equal("better_instance", instance)
  end

  def test_get_instance_object_doesnt_exist
    matcher = Matcher.new
    obj = matcher.get_instance_object(@bad_instance)
    assert_nil(obj)
  end

end
