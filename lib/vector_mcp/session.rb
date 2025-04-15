# frozen_string_literal: true

module VectorMCP
  # Holds state for a client connection session
  class Session
    attr_reader :server_info, :server_capabilities, :protocol_version, :client_info, :client_capabilities

    def initialize(server_info:, server_capabilities:, protocol_version:)
      @server_info = server_info
      @server_capabilities = server_capabilities
      @protocol_version = protocol_version

      @initialized = false
      @client_info = nil
      @client_capabilities = nil
    end

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

    def initialized?
      @initialized
    end

    # Helper to check client capabilities later if needed
    # def supports?(capability_key)
    #   @client_capabilities.key?(capability_key.to_s)
    # end
  end
end
