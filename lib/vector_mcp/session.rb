# frozen_string_literal: true

require_relative "sampling/request"
require_relative "sampling/result"
require_relative "errors"
require_relative "request_context"

module VectorMCP
  # Represents the state of a single client-server connection session in MCP.
  # It tracks initialization status, and negotiated capabilities between the client and server.
  #
  # @attr_reader server_info [Hash] Information about the server.
  # @attr_reader server_capabilities [Hash] Capabilities supported by the server.
  # @attr_reader protocol_version [String] The MCP protocol version used by the server.
  # @attr_reader client_info [Hash, nil] Information about the client, received during initialization.
  # @attr_reader client_capabilities [Hash, nil] Capabilities supported by the client, received during initialization.
  # @attr_reader request_context [RequestContext] The request context for this session.
  class Session
    attr_reader :server_info, :server_capabilities, :protocol_version, :client_info, :client_capabilities, :server, :transport, :id, :request_context
    attr_accessor :data # For user-defined session-specific storage

    # Initializes a new session.
    #
    # @param server [VectorMCP::Server] The server instance managing this session.
    # @param transport [VectorMCP::Transport::Base, nil] The transport handling this session. Required for sampling.
    # @param id [String] A unique identifier for this session (e.g., from transport layer).
    # @param request_context [RequestContext, Hash, nil] The request context for this session.
    def initialize(server, transport = nil, id: SecureRandom.uuid, request_context: nil)
      @server = server
      @transport = transport # Store the transport for sending requests
      @id = id
      @initialized_state = :pending # :pending, :succeeded, :failed
      @client_info = nil
      @client_capabilities = nil
      @data = {} # Initialize user data hash
      @logger = server.logger
      
      # Initialize request context
      @request_context = case request_context
                         when RequestContext
                           request_context
                         when Hash
                           RequestContext.new(**request_context)
                         else
                           RequestContext.new
                         end
    end

    # Marks the session as initialized using parameters from the client's `initialize` request.
    #
    # @param params [Hash] The parameters from the client's `initialize` request.
    #   Expected keys include "protocolVersion", "clientInfo", and "capabilities".
    # @return [Hash] A hash suitable for the server's `initialize` response result.
    def initialize!(params)
      raise InitializationError, "Session already initialized or initialization attempt in progress." unless @initialized_state == :pending

      # TODO: More robust validation of params against MCP spec for initialize request
      params["protocolVersion"]
      client_capabilities_raw = params["capabilities"]
      client_info_raw = params["clientInfo"]

      # For now, we mostly care about clientInfo and capabilities for the session object.
      # Protocol version matching is more of a server/transport concern at a lower level if strict checks are needed.
      @client_info = client_info_raw.transform_keys(&:to_sym) if client_info_raw.is_a?(Hash)
      @client_capabilities = client_capabilities_raw.transform_keys(&:to_sym) if client_capabilities_raw.is_a?(Hash)

      @initialized_state = :succeeded
      @logger.info("[Session #{@id}] Initialized successfully. Client: #{@client_info&.dig(:name)}")

      {
        protocolVersion: @server.protocol_version,
        serverInfo: @server.server_info,
        capabilities: @server.server_capabilities
      }
    rescue StandardError => e
      @initialized_state = :failed
      @logger.error("[Session #{@id}] Initialization failed: #{e.message}")
      # Re-raise as an InitializationError if it's not already one of our ProtocolErrors
      raise e if e.is_a?(ProtocolError)

      raise InitializationError, "Initialization processing error: #{e.message}", details: { original_error: e.to_s }
    end

    # Checks if the session has been successfully initialized.
    #
    # @return [Boolean] True if the session is initialized, false otherwise.
    def initialized?
      @initialized_state == :succeeded
    end

    # Sets the request context for this session.
    # This method should be called by transport layers to populate request-specific data.
    #
    # @param context [RequestContext, Hash] The request context to set.
    #   Can be a RequestContext object or a hash of attributes.
    # @return [RequestContext] The newly set request context.
    # @raise [ArgumentError] If the context is not a RequestContext or Hash.
    def set_request_context(context)
      @request_context = case context
                         when RequestContext
                           context
                         when Hash
                           RequestContext.new(**context)
                         else
                           raise ArgumentError, "Request context must be a RequestContext or Hash, got #{context.class}"
                         end
    end

    # Updates the request context with new data.
    # This merges the provided attributes with the existing context.
    #
    # @param attributes [Hash] The attributes to merge into the request context.
    # @return [RequestContext] The updated request context.
    def update_request_context(**attributes)
      current_attrs = @request_context.to_h
      
      # Deep merge nested hashes like headers and params
      merged_attrs = current_attrs.dup
      attributes.each do |key, value|
        if value.is_a?(Hash) && current_attrs[key].is_a?(Hash)
          merged_attrs[key] = current_attrs[key].merge(value)
        else
          merged_attrs[key] = value
        end
      end
      
      @request_context = RequestContext.new(**merged_attrs)
    end

    # Convenience method to check if the session has request headers.
    #
    # @return [Boolean] True if the request context has headers, false otherwise.
    def has_request_headers?
      @request_context.has_headers?
    end

    # Convenience method to check if the session has request parameters.
    #
    # @return [Boolean] True if the request context has parameters, false otherwise.
    def has_request_params?
      @request_context.has_params?
    end

    # Convenience method to get a request header value.
    #
    # @param name [String] The header name.
    # @return [String, nil] The header value or nil if not found.
    def request_header(name)
      @request_context.header(name)
    end

    # Convenience method to get a request parameter value.
    #
    # @param name [String] The parameter name.
    # @return [String, nil] The parameter value or nil if not found.
    def request_param(name)
      @request_context.param(name)
    end

    # Helper to check client capabilities later if needed
    # def supports?(capability_key)
    #   @client_capabilities.key?(capability_key.to_s)
    # end

    # --- MCP Sampling Method ---

    # Initiates an MCP sampling request to the client associated with this session.
    # This is a blocking call that waits for the client's response.
    #
    # @param request_params [Hash] Parameters for the `sampling/createMessage` request.
    #   See `VectorMCP::Sampling::Request` for expected structure (e.g., :messages, :max_tokens).
    # @param timeout [Numeric, nil] Optional timeout in seconds for this specific request.
    #   Defaults to the transport's default request timeout.
    # @return [VectorMCP::Sampling::Result] The result of the sampling operation.
    # @raise [VectorMCP::SamplingError] if the sampling request fails, is rejected, or times out.
    # @raise [StandardError] if the session's transport does not support `send_request`.
    def sample(request_params, timeout: nil)
      validate_sampling_preconditions

      # Create middleware context for sampling
      context = VectorMCP::Middleware::Context.new(
        operation_type: :sampling,
        operation_name: "createMessage",
        params: request_params,
        session: self,
        server: @server,
        metadata: { start_time: Time.now, timeout: timeout }
      )

      # Execute before_sampling_request hooks
      context = @server.middleware_manager.execute_hooks(:before_sampling_request, context)
      raise context.error if context.error?

      begin
        sampling_req_obj = VectorMCP::Sampling::Request.new(request_params)
        @logger.info("[Session #{@id}] Sending sampling/createMessage request to client.")

        result = send_sampling_request(sampling_req_obj, timeout)

        # Set result in context
        context.result = result

        # Execute after_sampling_response hooks
        context = @server.middleware_manager.execute_hooks(:after_sampling_response, context)

        context.result
      rescue StandardError => e
        # Set error in context and execute error hooks
        context.error = e
        context = @server.middleware_manager.execute_hooks(:on_sampling_error, context)

        # Re-raise unless middleware handled the error
        raise e unless context.result

        context.result
      end
    end

    private

    # Validates that sampling can be performed on this session.
    # @api private
    # @raise [StandardError, InitializationError] if preconditions are not met.
    def validate_sampling_preconditions
      unless @transport.respond_to?(:send_request)
        raise StandardError, "Session's transport does not support sending requests (required for sampling)."
      end

      return if initialized?

      @logger.warn("[Session #{@id}] Attempted to send sampling request on a non-initialized session.")
      raise InitializationError, "Cannot send sampling request: session not initialized."
    end

    # Sends the sampling request and handles the response.
    # @api private
    # @param sampling_req_obj [VectorMCP::Sampling::Request] The sampling request object.
    # @param timeout [Numeric, nil] Optional timeout for the request.
    # @return [VectorMCP::Sampling::Result] The sampling result.
    # @raise [VectorMCP::SamplingError] if the request fails.
    def send_sampling_request(sampling_req_obj, timeout)
      send_request_args = ["sampling/createMessage", sampling_req_obj.to_h]
      send_request_kwargs = {}
      send_request_kwargs[:timeout] = timeout if timeout

      raw_result = @transport.send_request(*send_request_args, **send_request_kwargs)
      VectorMCP::Sampling::Result.new(raw_result)
    rescue ArgumentError => e
      @logger.error("[Session #{@id}] Invalid parameters for sampling request or result: #{e.message}")
      raise VectorMCP::SamplingError.new("Invalid sampling parameters or malformed client response: #{e.message}", details: { original_error: e.to_s })
    rescue VectorMCP::SamplingError => e
      @logger.warn("[Session #{@id}] Sampling request failed: #{e.message}")
      raise e
    rescue StandardError => e
      @logger.error("[Session #{@id}] Unexpected error during sampling: #{e.class.name}: #{e.message}")
      raise VectorMCP::SamplingError.new("An unexpected error occurred during sampling: #{e.message}", details: { original_error: e.to_s })
    end
  end
end
