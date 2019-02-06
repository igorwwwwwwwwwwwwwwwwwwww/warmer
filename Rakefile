task default: %i[test]

desc 'test the tests'
task test: :prepare_test_env do
  ruby "test/test_server.rb"
  ruby "test/test_instance_checker.rb"
end

desc 'prepare the test environment'
task :prepare_test_env do
  unless %w[test development].include?(ENV['RACK_ENV'])
    raise "invalid RACK_ENV #{ENV['RACK_ENV']}"
  end

  require 'redis'

  pool_image = ENV.fetch(
    'WARMER_DEFAULT_POOLCONFIG_IMAGE',
    'travis-ci-amethyst-trusty-1512508224-986baf0:n1-standard-1'
  )

  machine_type = ENV.fetch(
    'WARMER_DEFAULT_POOLCONFIG_MACHINE_TYPE',
    'n1-standard-1'
  )

  redis = Redis.new
  redis.multi do |conn|
    conn.del('poolconfigs')
    conn.hset('poolconfigs', "#{pool_image}:#{machine_type}:public", '1')
    conn.hset('poolconfigs', "#{pool_image}:#{machine_type}", '1')
  end
end
