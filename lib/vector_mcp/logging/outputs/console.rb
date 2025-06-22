# frozen_string_literal: true

module VectorMCP
  module Logging
    module Outputs
      class Console < Base
        def initialize(config = {})
          super
          @stream = determine_stream
          @mutex = Mutex.new
        end

        protected

        def write_formatted(message)
          @mutex.synchronize do
            @stream.write(message)
            @stream.flush if @stream.respond_to?(:flush)
          end
        end

        private

        def determine_stream
          case @config[:stream]&.to_s&.downcase
          when "stdout"
            $stdout
          when "stderr"
            $stderr
          else
            $stderr # Default to stderr for logging
          end
        end
      end
    end
  end
end
