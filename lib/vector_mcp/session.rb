# frozen_string_literal: true

require_relative "sampling/request"
require_relative "sampling/result"
require_relative "errors"
require_relative "request_context"
require_relative "security/session_context"

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
    attr_reader :server_info, :server_capabilities, :protocol_version, :client_info, :client_capabilities, :server, :transport, :id,
                :request_context, :created_at, :last_accessed_at, :metadata
    attr_accessor :data, :security_context # For user-defined session-specific storage and resolved auth context

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
      @security_context = Security::SessionContext.anonymous
      @created_at = Time.now
      @last_accessed_at = @created_at
      @metadata = {} # Transport-owned lifecycle/connection state
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

    # --- Lifecycle (managed by the transport's session manager) ---

    # Records activity on this session, deferring expiry.
    # @return [void]
    def touch!
      @last_accessed_at = Time.now
    end

    # @param timeout [Numeric] Idle timeout in seconds.
    # @return [Boolean] True when the session has been idle longer than the timeout.
    def expired?(timeout)
      Time.now - @last_accessed_at > timeout
    end

    # @return [Float] Seconds since the session was created.
    def age
      Time.now - @created_at
    end

    # NOTE: The request-scoped convenience API that used to live here
    # (request_context=, update_request_context, request_headers?,
    # request_params?, request_header, request_param) was removed in 0.7.
    # Request-scoped data travels on the per-request {VectorMCP::Invocation}
    # passed to handlers; the session only keeps its creation-time context.

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
        @logger.debug("[Session #{@id}] Sending sampling/createMessage request to client.")

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

      # Prefer session-targeted request sending when available
      raw_result = if @transport.respond_to?(:send_request_to_session)
                     @transport.send_request_to_session(@id, *send_request_args, **send_request_kwargs)
                   else
                     # Fallback to generic send_request for transports without session targeting
                     @transport.send_request(*send_request_args, **send_request_kwargs)
                   end

      VectorMCP::Sampling::Result.new(raw_result)
    rescue ArgumentError => e
      @logger.error("[Session #{@id}] Invalid parameters for sampling request or result: #{e.message}")
      raise VectorMCP::SamplingError.new("Invalid sampling parameters or malformed client response: #{e.message}",
                                         details: { original_error: e.to_s })
    rescue VectorMCP::SamplingError => e
      @logger.warn("[Session #{@id}] Sampling request failed: #{e.message}")
      raise e
    rescue StandardError => e
      @logger.error("[Session #{@id}] Unexpected error during sampling: #{e.class.name}: #{e.message}")
      raise VectorMCP::SamplingError.new("An unexpected error occurred during sampling: #{e.message}", details: { original_error: e.to_s })
    end
  end
end
