# frozen_string_literal: true

module Warmer
  class Error < StandardError
  end

  # Thrown when an instance that is being created may have been orphaned in the process
  # and would need to be cleaned up.
  class InstanceOrphaned < Error
    attr_reader :instance

    def initialize(msg, instance)
      super msg
      @instance = instance
    end
  end
end
