# frozen_string_literal: true

module VectorMCP
  module Transport
    class SSE
      # Configures Puma server for production-ready SSE transport.
      # Handles server setup, threading, and resource management.
      class PumaConfig
        attr_reader :host, :port, :logger

        # Initializes Puma configuration.
        #
        # @param host [String] Host to bind to
        # @param port [Integer] Port to listen on
        # @param logger [Logger] Logger instance
        def initialize(host, port, logger)
          @host = host
          @port = port
          @logger = logger
        end

        # Configures a Puma server instance.
        #
        # @param server [Puma::Server] The Puma server to configure
        def configure(server)
          server.add_tcp_listener(host, port)

          # Configure threading for production use
          configure_threading(server)

          # Set up server options
          configure_server_options(server)

          logger.debug { "Puma server configured for #{host}:#{port}" }
        end

        private

        # Configures threading parameters for optimal performance.
        #
        # @param server [Puma::Server] The Puma server
        def configure_threading(server)
          # Set thread pool size based on CPU cores and expected load
          min_threads = 2
          max_threads = [4, Etc.nprocessors * 2].max

          # Puma 6.x does not expose min_threads= and max_threads= as public API.
          # Thread pool sizing should be set via Puma DSL/config before server creation.
          # For legacy compatibility, set if possible, otherwise log a warning.
          if server.respond_to?(:min_threads=) && server.respond_to?(:max_threads=)
            server.min_threads = min_threads
            server.max_threads = max_threads
            logger.debug { "Puma configured with #{min_threads}-#{max_threads} threads" }
          else
            logger.warn { "Puma::Server does not support direct thread pool sizing; set threads via Puma config DSL before server creation." }
          end
        end

        # Configures server-specific options.
        #
        # @param server [Puma::Server] The Puma server
        def configure_server_options(server)
          # Set server-specific options for SSE handling
          server.leak_stack_on_error = false if server.respond_to?(:leak_stack_on_error=)

          # Configure timeouts appropriate for SSE connections
          # SSE connections should be long-lived, so we set generous timeouts
          if server.respond_to?(:first_data_timeout=)
            server.first_data_timeout = 30 # 30 seconds to send first data
          end

          logger.debug { "Puma server options configured for SSE transport" }
        end
      end
    end
  end
end
