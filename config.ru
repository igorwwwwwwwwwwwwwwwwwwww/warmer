libdir = File.expand_path('./lib', __dir__)
$LOAD_PATH.unshift(libdir) unless $LOAD_PATH.include?(libdir)

require 'warmer'

$stdout.sync = true
$stderr.sync = true

run Warmer::App
