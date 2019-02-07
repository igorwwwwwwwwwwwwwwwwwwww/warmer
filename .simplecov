if ENV['COVERAGE']
  SimpleCov.start do
    add_filter 'test/'
  end

  if ENV['TRAVIS']
    require 'codecov'
    SimpleCov.formatter = SimpleCov::Formatter::Codecov
  end
end
