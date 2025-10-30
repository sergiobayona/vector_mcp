# frozen_string_literal: true

require "async"
require "async/http/endpoint"
require "falcon/server"

module VectorMCP
  module Transport
    class HttpStream
      # Configures Falcon server for production-ready HTTP Stream transport.
      # Handles server setup, fiber-based concurrency, and resource management.
      # Falcon uses async I/O and fiber-based concurrency for efficient handling
      # of long-lived SSE connections and concurrent MCP clients.
      class FalconConfig
        attr_reader :host, :port, :logger, :endpoint

        # Default configuration values
        DEFAULT_CONTAINER_COUNT = nil # Auto-detect based on CPU cores
        DEFAULT_CACHE_SIZE = 1024 # Cache size for HTTP responses

        # Initializes Falcon configuration.
        #
        # @param host [String] Host to bind to
        # @param port [Integer] Port to listen on
        # @param logger [Logger] Logger instance
        # @param options [Hash] Additional configuration options
        # @option options [Integer] :container_count Number of container processes (nil = auto-detect)
        # @option options [Integer] :cache_size HTTP response cache size
        def initialize(host, port, logger, options = {})
          @host = host
          @port = port
          @logger = logger
          @options = options
          @container_count = options[:container_count] || DEFAULT_CONTAINER_COUNT
          @cache_size = options[:cache_size] || DEFAULT_CACHE_SIZE
          @async_task = nil
          @server_task = nil

          # Create HTTP endpoint for Falcon
          @endpoint = create_endpoint
        end

        # Creates and configures a Falcon server instance.
        #
        # @param rack_app [#call] The Rack application to serve
        # @return [Falcon::Server] Configured Falcon server
        def create_server(rack_app)
          middleware = Falcon::Server.middleware(
            rack_app,
            verbose: @options.fetch(:verbose, false),
            cache: @options.fetch(:cache, true)
          )

          server = Falcon::Server.new(middleware, @endpoint)

          # Configure server options
          configure_server_options(server)

          logger.debug { "Falcon server configured for #{@host}:#{@port}" }
          logger.debug { "Endpoint: #{@endpoint.inspect}" }

          server
        end

        # Runs the Falcon server with async reactor.
        # This method blocks until the server is stopped.
        #
        # @param rack_app [#call] The Rack application to serve
        # @yield [Async::Task] Yields the async task used to control the server before blocking
        # @return [void]
        def run(rack_app)
          logger.info { "Starting Falcon server on #{@host}:#{@port}" }

          Async do |task|
            @async_task = task
            yield task if block_given?

            server = create_server(rack_app)

            begin
              @server_task = server.run
              logger.info { "Falcon server started successfully" }

              @server_task.wait
            rescue Async::Stop
              logger.debug { "Falcon server task cancelled" }
            rescue StandardError => e
              logger.error { "Error running Falcon server: #{e.message}" }
              logger.error { e.backtrace.join("\n") }
              raise
            ensure
              logger.info { "Falcon server shutdown" }
              @server_task = nil
              @async_task = nil
            end
          end.wait
        end

        # Gracefully stops the Falcon server.
        #
        # @param server [Falcon::Server, nil] The server to stop
        # @return [void]
        def stop_server(_server = nil)
          return unless @async_task || @server_task

          logger.info { "Stopping Falcon server" }
          begin
            server_task = @server_task if @server_task.respond_to?(:stop)
            server_task&.stop

            if @async_task
              begin
                @async_task.stop
              rescue NoMethodError => e
                raise unless e.receiver.nil? && e.name == :raise

                logger.debug { "Falcon async task already stopped" }
              end
            end

            server_task&.wait if server_task.respond_to?(:wait)
          ensure
            @server_task = nil
            @async_task = nil
          end
        rescue StandardError => e
          logger.error { "Error stopping Falcon server: #{e.message}" }
        end

        private

        # Creates an Async::HTTP::Endpoint for Falcon.
        #
        # @return [Async::HTTP::Endpoint] Configured endpoint
        def create_endpoint
          # Create endpoint URL
          url = "http://#{@host}:#{@port}"

          # Parse endpoint with proper SSL/TLS configuration if needed
          endpoint = Async::HTTP::Endpoint.parse(url)

          # Configure endpoint options
          configure_endpoint_options(endpoint)

          endpoint
        end

        # Configures endpoint-specific options.
        #
        # @param endpoint [Async::HTTP::Endpoint] The endpoint to configure
        # @return [void]
        def configure_endpoint_options(_endpoint)
          # Endpoint options can be configured here if needed
          # For now, we use the defaults which work well for SSE and HTTP streaming

          logger.debug { "Endpoint configured with default options for SSE support" }
        end

        # Configures server-specific options for optimal SSE and MCP performance.
        #
        # @param server [Falcon::Server] The Falcon server
        # @return [void]
        def configure_server_options(server)
          # Falcon uses fiber-based concurrency, so we configure the fiber scheduler
          # rather than thread pools

          # Set cache size for HTTP responses if server supports it
          if server.respond_to?(:cache_size=)
            server.cache_size = @cache_size
            logger.debug { "Falcon cache size set to #{@cache_size}" }
          end

          # Falcon automatically handles:
          # - Fiber scheduling for concurrent connections
          # - HTTP/1.1 and HTTP/2 support
          # - Keep-alive connections
          # - Proper SSE streaming with non-blocking I/O

          logger.debug { "Falcon server options configured for MCP transport" }
        end

        # Calculates optimal container count based on CPU cores.
        #
        # @return [Integer] Number of container processes to use
        def calculate_container_count
          return @container_count if @container_count

          # Auto-detect based on CPU cores
          # For I/O-bound MCP workloads, we use fewer containers than CPU cores
          # since Falcon's async I/O handles concurrency efficiently
          cores = Etc.nprocessors
          [(cores / 2).ceil, 1].max
        rescue StandardError => e
          logger.warn { "Could not detect CPU count: #{e.message}. Using 1 container." }
          1
        end
      end
    end
  end
end
