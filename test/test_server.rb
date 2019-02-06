require 'simplecov'

require 'json'

require 'rack/test'
require 'minitest/autorun'
require 'mocha/minitest'

libdir = File.expand_path('../lib', __dir__)
$LOAD_PATH.unshift(libdir) unless $LOAD_PATH.include?(libdir)

require 'warmer'

class ServerTest < Minitest::Test
  include Rack::Test::Methods

  def app
    Warmer::App
  end

  def setup
    @request_body = JSON.parse("{\"image_name\": \"https://www.googleapis.com/compute/v1/projects/eco-emissary-99515/global/images/super-great-fake-image\",
      \"machine_type\": \"n1-standard-1\",
      \"public_ip\": \"true\"}")

    @instance = "{\"name\": \"super-great-test-instance\", \"zone\": \"us-central1-c\"}"
    @bad_instance = "{\"name\": \"im-not-real\", \"zone\": \"us-central1-c\"}"
  end

  def test_get_root
    get '/'
    assert_equal("warmer no warming", last_response.body)
  end

  def test_post_request_instance
    post '/request-instance', @request_body.to_json, { 'CONTENT_TYPE' => 'application/json' }
    # We know we won't get a VM for a fake image, but we want to make sure all the parsing happens
    assert_equal(404, last_response.status)
  end

  def test_get_pool_configs
    get '/pool-configs'
    assert last_response.ok?

    get '/pool-configs/fake-test-pool'
    assert_equal(404, last_response.status)
  end

  def test_set_and_delete_pool_config
    post '/pool-configs/super:testpool/1'
    assert last_response.ok?

    get '/pool-configs/super:testpool'
    assert last_response.ok?

    delete '/pool-configs/super:testpool'
    assert last_response.ok?

    get '/pool-configs/super:testpool'
    assert_equal(404, last_response.status)
  end

  def test_match
    matcher = Warmer::Matcher.new
    assert(true, matcher.match(@request_body))
  end

  def test_request_instance_empty_redis
    matcher = Warmer::Matcher.new
    instance = matcher.request_instance('fake_group')
    assert_equal(nil, instance)
  end

  def test_request_instance
    fake_redis = mock()
    fake_redis.stubs(:lpop).returns("cool_instance")
    matcher = Warmer::Matcher.new
    matcher.stubs(:get_instance_object).returns(true)
    matcher.stubs(:label_instance).returns(true)
    Warmer.stubs(:redis).returns(fake_redis)

    instance = matcher.request_instance('fake_group')
    assert_equal("cool_instance", instance)

  end

  def test_request_instance_doesnt_exist
    fake_redis = mock()
    fake_redis.stubs(:lpop).returns("cool_instance", "better_instance")
    matcher = Warmer::Matcher.new
    matcher.stubs(:get_instance_object).returns(nil, true)
    matcher.stubs(:label_instance).returns(true)
    Warmer.stubs(:redis).returns(fake_redis)

    instance = matcher.request_instance('fake_group')
    assert_equal("better_instance", instance)
  end

  def test_get_instance_object_doesnt_exist
    matcher = Warmer::Matcher.new
    obj = matcher.send(:get_instance_object, @bad_instance)
    assert_nil(obj)
  end
end
