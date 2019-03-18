# frozen_string_literal: true

module Warmer
  class Error < StandardError
  end

  class InstanceOrphaned < Error
    attr_reader :instance

    def initialize(msg, instance)
      super msg
      @instance = instance
    end
  end
end
