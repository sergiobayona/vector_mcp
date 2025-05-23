# frozen_string_literal: true

require_relative "sampling/request"
require_relative "sampling/result"
require_relative "errors"

module VectorMCP
  # Represents the state of a single client-server connection session in MCP.
  # It tracks initialization status, and negotiated capabilities between the client and server.
  #
  # @attr_reader server_info [Hash] Information about the server.
  # @attr_reader server_capabilities [Hash] Capabilities supported by the server.
  # @attr_reader protocol_version [String] The MCP protocol version used by the server.
  # @attr_reader client_info [Hash, nil] Information about the client, received during initialization.
  # @attr_reader client_capabilities [Hash, nil] Capabilities supported by the client, received during initialization.
  class Session
    attr_reader :server_info, :server_capabilities, :protocol_version, :client_info, :client_capabilities, :server, :transport, :id
    attr_accessor :data # For user-defined session-specific storage

    # Initializes a new session.
    #
    # @param server [VectorMCP::Server] The server instance managing this session.
    # @param transport [VectorMCP::Transport::Base, nil] The transport handling this session. Required for sampling.
    # @param id [String] A unique identifier for this session (e.g., from transport layer).
    def initialize(server, transport = nil, id: SecureRandom.uuid)
      @server = server
      @transport = transport # Store the transport for sending requests
      @id = id
      @initialized_state = :pending # :pending, :succeeded, :failed
      @client_info = nil
      @client_capabilities = nil
      @data = {} # Initialize user data hash
      @logger = server.logger
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
      unless @transport.respond_to?(:send_request)
        raise StandardError, "Session's transport does not support sending requests (required for sampling)."
      end

      unless initialized?
        # Or raise an error, depending on desired strictness. Client shouldn't allow sampling before init.
        @logger.warn("[Session #{@id}] Attempted to send sampling request on a non-initialized session.")
        raise InitializationError, "Cannot send sampling request: session not initialized."
      end

      sampling_req_obj = VectorMCP::Sampling::Request.new(request_params)
      @logger.info("[Session #{@id}] Sending sampling/createMessage request to client.")

      begin
        # Construct arguments for transport.send_request, including timeout if provided
        send_request_args = ["sampling/createMessage", sampling_req_obj.to_h]
        send_request_kwargs = {}
        send_request_kwargs[:timeout] = timeout if timeout

        raw_result = @transport.send_request(*send_request_args, **send_request_kwargs)

        VectorMCP::Sampling::Result.new(raw_result)
      rescue ArgumentError => e # From Sampling::Request.new or if raw_result is bad for Sampling::Result
        @logger.error("[Session #{@id}] Invalid parameters for sampling request or result: #{e.message}")
        raise VectorMCP::SamplingError, "Invalid sampling parameters or malformed client response: #{e.message}", details: { original_error: e.to_s }
      rescue VectorMCP::SamplingError => e # Timeout or client error already wrapped by transport
        @logger.warn("[Session #{@id}] Sampling request failed: #{e.message}")
        raise e # Re-raise to propagate
      rescue StandardError => e # Other unexpected errors from transport or result processing
        @logger.error("[Session #{@id}] Unexpected error during sampling: #{e.class.name}: #{e.message}")
        raise VectorMCP::SamplingError, "An unexpected error occurred during sampling: #{e.message}", details: { original_error: e.to_s }
      end
    end
  end
end
