# frozen_string_literal: true

module Travis
  def config
    ::Warmer.config
  end

  module_function :config

  def logger
    ::Warmer.logger
  end

  module_function :logger
end
