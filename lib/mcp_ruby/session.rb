# frozen_string_literal: true

module MCPRuby
  # Basic Session state
  class Session
    attr_reader :client_capabilities, :server_capabilities, :server_info, :protocol_version

    def initialize(server_info:, server_capabilities:, protocol_version:)
      @initialized = false
      @client_capabilities = {}
      @server_info = server_info
      @server_capabilities = server_capabilities
      @protocol_version = protocol_version # The version the *server* wants to use
    end

    def initialize!(client_params)
      client_protocol_version = client_params["protocolVersion"]
      # Basic version check (can be more sophisticated)
      unless client_protocol_version == @protocol_version
        # For now, log a warning but proceed. Strict servers might error.
        # raise MCPRuby::ProtocolError.new("Unsupported protocol version: #{client_protocol_version}", code: -32603)
        MCPRuby.logger.warn("Client requested protocol version '#{client_protocol_version}', server using '#{@protocol_version}'")
      end

      @client_capabilities = client_params["capabilities"] || {}
      @initialized = true
      {
        protocolVersion: @protocol_version,
        capabilities: @server_capabilities,
        serverInfo: @server_info
        # instructions: "Optional server instructions"
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
