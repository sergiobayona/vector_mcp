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
          @async_task = nil
          @server_task = nil

          # Create HTTP endpoint for Falcon
          @endpoint = create_endpoint
        end

        # Gracefully stops the Falcon server task if it is running.
        #
        # @param _server [Falcon::Server, nil] The server to stop (unused; kept for API parity)
        # @return [void]
        def stop_server(_server = nil)
          return unless @async_task || @server_task

          logger.info { "Stopping Falcon SSE server" }

          begin
            stop_server_task
            stop_async_task
          ensure
            clear_tasks
          end
        rescue StandardError => e
          logger.error { "Error stopping Falcon SSE server: #{e.message}" }
        end

        # Creates and configures a Falcon server instance.
        #
        # @param rack_app [#call] The Rack application to serve
        # @return [Falcon::Server] Configured Falcon server
        def create_server(rack_app)
          middleware = Falcon::Server.middleware(
            rack_app,
            verbose: @options.fetch(:verbose, false),
            cache: @options.fetch(:cache, false)
          )

          server = Falcon::Server.new(middleware, @endpoint)

          # Configure server options optimized for SSE
          configure_server_options(server)

          logger.debug { "Falcon server configured for SSE on #{@host}:#{@port}" }

          server
        end

        # Runs the Falcon server with async reactor.
        # This method blocks until the server is stopped.
        #
        # @param rack_app [#call] The Rack application to serve
        # @yield [Async::Task] Yields the async task used to control the server before blocking
        # @return [void]
        def run(rack_app)
          logger.info { "Starting Falcon SSE server on #{@host}:#{@port}" }

          Async do |task|
            @async_task = task
            yield task if block_given?

            server = create_server(rack_app)

            begin
              @server_task = server.run
              logger.info { "Falcon SSE server started successfully" }

              @server_task.wait
            rescue Async::Stop
              logger.debug { "Falcon SSE server task cancelled" }
            rescue StandardError => e
              logger.error { "Error running Falcon SSE server: #{e.message}" }
              logger.error { e.backtrace.join("\n") }
              raise
            ensure
              logger.info { "Falcon SSE server shutdown" }
              @server_task = nil
              @async_task = nil
            end
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

        # Stops the server task if it's running.
        #
        # @return [void]
        def stop_server_task
          server_task = @server_task if @server_task.respond_to?(:stop)
          server_task&.stop
          server_task&.wait if server_task.respond_to?(:wait)
        end

        # Stops the async task if it's running.
        #
        # @return [void]
        def stop_async_task
          return unless @async_task

          begin
            @async_task.stop
          rescue NoMethodError => e
            raise unless e.receiver.nil? && e.name == :raise

            logger.debug { "Falcon SSE async task already stopped" }
          end
        end

        # Clears the task references.
        #
        # @return [void]
        def clear_tasks
          @server_task = nil
          @async_task = nil
        end

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
        def configure_endpoint_for_sse(_endpoint)
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
