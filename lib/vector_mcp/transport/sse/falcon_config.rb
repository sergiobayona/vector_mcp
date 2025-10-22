# frozen_string_literal: true

require "async"
require "async/http/endpoint"
require "falcon/server"

module VectorMCP
  module Transport
    class SSE
      # Configures Falcon server for production-ready SSE transport.
      # Handles server setup, fiber-based concurrency, and resource management.
      # Optimized for Server-Sent Events (SSE) with long-lived connections.
      class FalconConfig
        attr_reader :host, :port, :logger, :endpoint

        # Default configuration values
        DEFAULT_CACHE_SIZE = 512 # Smaller cache for SSE-focused server

        # Initializes Falcon configuration.
        #
        # @param host [String] Host to bind to
        # @param port [Integer] Port to listen on
        # @param logger [Logger] Logger instance
        # @param options [Hash] Additional configuration options
        # @option options [Integer] :cache_size HTTP response cache size
        def initialize(host, port, logger, options = {})
          @host = host
          @port = port
          @logger = logger
          @options = options
          @cache_size = options[:cache_size] || DEFAULT_CACHE_SIZE

          # Create HTTP endpoint for Falcon
          @endpoint = create_endpoint
        end

        # Creates and configures a Falcon server instance.
        #
        # @param rack_app [#call] The Rack application to serve
        # @return [Falcon::Server] Configured Falcon server
        def create_server(rack_app)
          server = Falcon::Server.new(rack_app, @endpoint)

          # Configure server options optimized for SSE
          configure_server_options(server)

          logger.debug { "Falcon server configured for SSE on #{@host}:#{@port}" }

          server
        end

        # Runs the Falcon server with async reactor.
        # This method blocks until the server is stopped.
        #
        # @param rack_app [#call] The Rack application to serve
        # @return [void]
        def run(rack_app)
          logger.info { "Starting Falcon SSE server on #{@host}:#{@port}" }

          # Run server in async reactor
          Async do |task|
            server = create_server(rack_app)

            # Falcon's run method handles the server loop
            server.run

            logger.info { "Falcon SSE server started successfully" }
          rescue StandardError => e
            logger.error { "Error running Falcon SSE server: #{e.message}" }
            logger.error { e.backtrace.join("\n") }
            raise
          ensure
            logger.info { "Falcon SSE server shutdown" }
          end.wait
        end

        # Configures a Falcon server instance (legacy API for compatibility).
        # Prefer using create_server and run methods instead.
        #
        # @param server [Falcon::Server] The Falcon server to configure
        # @deprecated Use {#create_server} and {#run} instead
        def configure(server)
          logger.warn { "FalconConfig#configure is deprecated. Use create_server and run instead." }
          configure_server_options(server)
        end

        private

        # Creates an Async::HTTP::Endpoint for Falcon.
        #
        # @return [Async::HTTP::Endpoint] Configured endpoint
        def create_endpoint
          url = "http://#{@host}:#{@port}"
          endpoint = Async::HTTP::Endpoint.parse(url)

          # Configure endpoint for long-lived SSE connections
          configure_endpoint_for_sse(endpoint)

          endpoint
        end

        # Configures endpoint specifically for SSE streaming.
        #
        # @param endpoint [Async::HTTP::Endpoint] The endpoint to configure
        # @return [void]
        def configure_endpoint_for_sse(endpoint)
          # SSE connections should be long-lived with minimal timeouts
          # Falcon handles this automatically with async I/O

          logger.debug { "Endpoint configured for SSE streaming" }
        end

        # Configures server-specific options for optimal SSE performance.
        #
        # @param server [Falcon::Server] The Falcon server
        # @return [void]
        def configure_server_options(server)
          # Set cache size if server supports it
          if server.respond_to?(:cache_size=)
            server.cache_size = @cache_size
            logger.debug { "Falcon cache size set to #{@cache_size} for SSE" }
          end

          # Falcon automatically provides:
          # - Non-blocking I/O for SSE streams
          # - Fiber-based concurrency for multiple SSE connections
          # - Proper HTTP/1.1 chunked transfer encoding for SSE
          # - Keep-alive connection management
          # - Graceful connection cleanup on client disconnect

          logger.debug { "Falcon server options configured for SSE transport" }
        end
      end
    end
  end
end
