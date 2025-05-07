# frozen_string_literal: true

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
    attr_reader :server_info, :server_capabilities, :protocol_version, :client_info, :client_capabilities

    # Initializes a new session.
    #
    # @param server_info [Hash] Hash containing server information (e.g., name, version).
    # @param server_capabilities [Hash] Hash describing server capabilities.
    # @param protocol_version [String] The protocol version the server adheres to.
    def initialize(server_info:, server_capabilities:, protocol_version:)
      @server_info = server_info
      @server_capabilities = server_capabilities
      @protocol_version = protocol_version

      @initialized = false
      @client_info = nil
      @client_capabilities = nil
    end

    # Marks the session as initialized using parameters from the client's `initialize` request.
    #
    # @param params [Hash] The parameters from the client's `initialize` request.
    #   Expected keys include "protocolVersion", "clientInfo", and "capabilities".
    # @return [Hash] A hash suitable for the server's `initialize` response result.
    def initialize!(params)
      client_protocol_version = params["protocolVersion"]

      if client_protocol_version != @protocol_version
        # raise VectorMCP::ProtocolError.new("Unsupported protocol version: #{client_protocol_version}", code: -32603)
        VectorMCP.logger.warn("Client requested protocol version '#{client_protocol_version}', server using '#{@protocol_version}'")
      end

      @client_info = params["clientInfo"] || {}
      @client_capabilities = params["capabilities"] || {}
      @initialized = true

      # Return the initialize result (will be sent by transport)
      {
        protocolVersion: @protocol_version,
        serverInfo: @server_info,
        capabilities: @server_capabilities
      }
    end

    # Checks if the session has been successfully initialized.
    #
    # @return [Boolean] True if the session is initialized, false otherwise.
    def initialized?
      @initialized
    end

    # Helper to check client capabilities later if needed
    # def supports?(capability_key)
    #   @client_capabilities.key?(capability_key.to_s)
    # end
  end
end
