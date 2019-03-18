# frozen_string_literal: true

module Warmer
  # Adapters allow creating instances on different cloud providers or APIs.
  # An adapter encapsulates all the provider-specific behavior of warmer.
  module Adapter
    autoload :Google, 'warmer/adapter/google'
  end
end
