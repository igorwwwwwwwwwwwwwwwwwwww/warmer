# frozen_string_literal: true

begin
  require 'rubocop/rake_task'
  require 'rspec/core/rake_task'
rescue LoadError => e
  warn e
end

require 'rake/testtask'

RuboCop::RakeTask.new if defined?(RuboCop)

RSpec::Core::RakeTask.new if defined?(RSpec)

desc 'prepare the test environment'
task :prepare_test_env do
  raise "invalid RACK_ENV #{ENV['RACK_ENV']}" unless %w[test development].include?(ENV['RACK_ENV'])

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

task default: %i[rubocop spec]
