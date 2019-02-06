if ENV['COVERAGE']
  SimpleCov.start do
    add_filter 'test/'
  end
end
