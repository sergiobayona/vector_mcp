# frozen_string_literal: true

require "json"
require "uri"
require "json-schema"
require_relative "../middleware"

module VectorMCP
  module Handlers
    # Provides default handlers for the core MCP methods.
    # These methods are typically registered on a {VectorMCP::Server} instance.
    # All public methods are designed to be called by the server's message dispatching logic.
    #
    # @see VectorMCP::Server#setup_default_handlers
    module Core
      # --- Request Handlers ---

      # Handles the `ping` request.
      #
      # @param _params [Hash] The request parameters (ignored).
      # @param _session [VectorMCP::Session] The current session (ignored).
      # @param _server [VectorMCP::Server] The server instance (ignored).
      # @return [Hash] An empty hash, as per MCP spec for ping.
      def self.ping(_params, _session, _server)
        {}
      end

      # Handles the `tools/list` request.
      #
      # @param _params [Hash] The request parameters (ignored).
      # @param _session [VectorMCP::Session] The current session (ignored).
      # @param server [VectorMCP::Server] The server instance.
      # @return [Hash] A hash containing an array of tool definitions.
      #   Example: `{ tools: [ { name: "my_tool", ... } ] }`
      def self.list_tools(_params, _session, server)
        {
          tools: server.tools.values.map(&:as_mcp_definition)
        }
      end

      # Handles the `tools/call` request.
      #
      # @param params [Hash] The request parameters.
      #   Expected keys: "name" (String), "arguments" (Hash, optional).
      # @param session [VectorMCP::Session] The current session.
      # @param server [VectorMCP::Server] The server instance.
      # @return [Hash] A hash containing the tool call result or an error indication.
      #   Example success: `{ isError: false, content: [{ type: "text", ... }] }`
      # @raise [VectorMCP::NotFoundError] if the requested tool is not found.
      # @raise [VectorMCP::InvalidParamsError] if arguments validation fails.
      # @raise [VectorMCP::UnauthorizedError] if authentication fails.
      # @raise [VectorMCP::ForbiddenError] if authorization fails.
      def self.call_tool(params, session, server)
        tool_name = params["name"]
        arguments = params["arguments"] || {}

        context = create_tool_context(tool_name, params, session, server)
        context = server.middleware_manager.execute_hooks(:before_tool_call, context)
        return handle_middleware_error(context) if context.error?

        begin
          tool = find_tool!(tool_name, server)
          security_result = validate_tool_security!(session, tool, server)
          validate_input_arguments!(tool_name, tool, arguments)

          result = execute_tool_handler(tool, arguments, security_result, session)
          context.result = build_tool_result(result)

          context = server.middleware_manager.execute_hooks(:after_tool_call, context)
          context.result
        rescue StandardError => e
          handle_tool_error(e, context, server)
        end
      end

      # Handles the `resources/list` request.
      #
      # @param _params [Hash] The request parameters (ignored).
      # @param _session [VectorMCP::Session] The current session (ignored).
      # @param server [VectorMCP::Server] The server instance.
      # @return [Hash] A hash containing an array of resource definitions.
      #   Example: `{ resources: [ { uri: "memory://data", name: "My Data", ... } ] }`
      def self.list_resources(_params, _session, server)
        {
          resources: server.resources.values.map(&:as_mcp_definition)
        }
      end

      # Handles the `resources/read` request.
      #
      # @param params [Hash] The request parameters.
      #   Expected key: "uri" (String).
      # @param session [VectorMCP::Session] The current session.
      # @param server [VectorMCP::Server] The server instance.
      # @return [Hash] A hash containing an array of content items from the resource.
      #   Example: `{ contents: [{ type: "text", text: "...", uri: "memory://data" }] }`
      # @raise [VectorMCP::NotFoundError] if the requested resource URI is not found.
      # @raise [VectorMCP::UnauthorizedError] if authentication fails.
      # @raise [VectorMCP::ForbiddenError] if authorization fails.
      def self.read_resource(params, session, server)
        uri_s = params["uri"]

        context = create_resource_context(uri_s, params, session, server)
        context = server.middleware_manager.execute_hooks(:before_resource_read, context)
        return handle_middleware_error(context) if context.error?

        begin
          resource = find_resource!(uri_s, server)
          security_result = validate_resource_security!(session, resource, server)

          content_raw = execute_resource_handler(resource, params, security_result)
          contents = process_resource_content(content_raw, resource, uri_s)

          context.result = { contents: contents }
          context = server.middleware_manager.execute_hooks(:after_resource_read, context)
          context.result
        rescue StandardError => e
          handle_resource_error(e, context, server)
        end
      end

      # Handles the `prompts/list` request.
      # If the server supports dynamic prompt lists, this clears the `listChanged` flag.
      #
      # @param _params [Hash] The request parameters (ignored).
      # @param _session [VectorMCP::Session] The current session (ignored).
      # @param server [VectorMCP::Server] The server instance.
      # @return [Hash] A hash containing an array of prompt definitions.
      #   Example: `{ prompts: [ { name: "my_prompt", ... } ] }`
      def self.list_prompts(_params, _session, server)
        # Once the list is supplied, clear the listChanged flag
        result = {
          prompts: server.prompts.values.map(&:as_mcp_definition)
        }
        server.clear_prompts_list_changed if server.respond_to?(:clear_prompts_list_changed)
        result
      end

      # Handles the `roots/list` request.
      # Returns the list of available roots and clears the `listChanged` flag.
      #
      # @param _params [Hash] The request parameters (ignored).
      # @param _session [VectorMCP::Session] The current session (ignored).
      # @param server [VectorMCP::Server] The server instance.
      # @return [Hash] A hash containing an array of root definitions.
      #   Example: `{ roots: [ { uri: "file:///path/to/dir", name: "My Project" } ] }`
      def self.list_roots(_params, _session, server)
        # Once the list is supplied, clear the listChanged flag
        result = {
          roots: server.roots.values.map(&:as_mcp_definition)
        }
        server.clear_roots_list_changed if server.respond_to?(:clear_roots_list_changed)
        result
      end

      # Handles the `prompts/subscribe` request (placeholder).
      # This implementation is a simple acknowledgement.
      #
      # @param _params [Hash] The request parameters (ignored).
      # @param session [VectorMCP::Session] The current session.
      # @param server [VectorMCP::Server] The server instance.
      # @return [Hash] An empty hash.
      def self.subscribe_prompts(_params, session, server)
        # Use private helper via send to avoid making it public
        server.send(:subscribe_prompts, session) if server.respond_to?(:send)
        {}
      end

      # Handles the `prompts/get` request.
      # Validates arguments and the structure of the prompt handler's response.
      #
      # @param params [Hash] The request parameters.
      #   Expected keys: "name" (String), "arguments" (Hash, optional).
      # @param _session [VectorMCP::Session] The current session (ignored).
      # @param server [VectorMCP::Server] The server instance.
      # @return [Hash] The result from the prompt's handler, which should conform to MCP's GetPromptResult.
      # @raise [VectorMCP::NotFoundError] if the prompt name is not found.
      # @raise [VectorMCP::InvalidParamsError] if arguments are invalid.
      # @raise [VectorMCP::InternalError] if the prompt handler returns an invalid data structure.
      def self.get_prompt(params, session, server)
        prompt_name = params["name"]

        # Create middleware context
        context = VectorMCP::Middleware::Context.new(
          operation_type: :prompt_get,
          operation_name: prompt_name,
          params: params,
          session: session,
          server: server,
          metadata: { start_time: Time.now }
        )

        # Execute before_prompt_get hooks
        context = server.middleware_manager.execute_hooks(:before_prompt_get, context)
        return handle_middleware_error(context) if context.error?

        begin
          prompt = fetch_prompt(prompt_name, server)

          arguments = params["arguments"] || {}
          validate_arguments!(prompt_name, prompt, arguments)

          # Call the registered handler after arguments were validated
          result_data = prompt.handler.call(arguments)

          validate_prompt_response!(prompt_name, result_data, server)

          # Set result in context
          context.result = result_data

          # Execute after_prompt_get hooks
          context = server.middleware_manager.execute_hooks(:after_prompt_get, context)

          context.result
        rescue StandardError => e
          # Set error in context and execute error hooks
          context.error = e
          context = server.middleware_manager.execute_hooks(:on_prompt_error, context)

          # Re-raise unless middleware handled the error
          raise e unless context.result

          context.result
        end
      end

      # --- Notification Handlers ---

      # Handles the `initialized` notification from the client.
      #
      # @param _params [Hash] The notification parameters (ignored).
      # @param _session [VectorMCP::Session] The current session (ignored, but state is on server).
      # @param server [VectorMCP::Server] The server instance.
      # @return [void]
      def self.initialized_notification(_params, _session, server)
        server.logger.info("Session initialized")
      end

      # Handles the `$/cancelRequest` notification from the client.
      #
      # @param params [Hash] The notification parameters. Expected key: "id".
      # @param _session [VectorMCP::Session] The current session (ignored).
      # @param server [VectorMCP::Server] The server instance.
      # @return [void]
      def self.cancel_request_notification(params, _session, server)
        request_id = params["id"]
        server.logger.info("Received cancellation request for ID: #{request_id}")
        # Application-specific cancellation logic would go here
        # Access in-flight requests via server.in_flight_requests[request_id]
      end

      # --- Helper methods (internal) ---

      # Fetches a prompt by its name from the server.
      # @api private
      # @param prompt_name [String] The name of the prompt to fetch.
      # @param server [VectorMCP::Server] The server instance.
      # @return [VectorMCP::Definitions::Prompt] The prompt definition.
      # @raise [VectorMCP::NotFoundError] if the prompt is not found.
      def self.fetch_prompt(prompt_name, server)
        prompt = server.prompts[prompt_name]
        return prompt if prompt

        raise VectorMCP::NotFoundError.new("Not Found", details: "Prompt not found: #{prompt_name}")
      end
      private_class_method :fetch_prompt

      # Validates arguments provided for a prompt against its definition.
      # @api private
      # @param prompt_name [String] The name of the prompt.
      # @param prompt [VectorMCP::Definitions::Prompt] The prompt definition.
      # @param arguments [Hash] The arguments supplied by the client.
      # @return [void]
      # @raise [VectorMCP::InvalidParamsError] if arguments are invalid (e.g., missing, unknown, wrong type).
      def self.validate_arguments!(prompt_name, prompt, arguments)
        ensure_hash!(prompt_name, arguments, "arguments")

        arg_defs = prompt.respond_to?(:arguments) ? (prompt.arguments || []) : []
        missing, unknown = argument_diffs(arg_defs, arguments)

        return if missing.empty? && unknown.empty?

        raise VectorMCP::InvalidParamsError.new("Invalid arguments",
                                                details: build_invalid_arg_details(prompt_name, missing, unknown))
      end
      private_class_method :validate_arguments!

      # Ensures a given value is a Hash.
      # @api private
      # @param prompt_name [String] The name of the prompt (for error reporting).
      # @param value [Object] The value to check.
      # @param field_name [String] The name of the field being checked (for error reporting).
      # @return [void]
      # @raise [VectorMCP::InvalidParamsError] if the value is not a Hash.
      def self.ensure_hash!(prompt_name, value, field_name)
        return if value.is_a?(Hash)

        raise VectorMCP::InvalidParamsError.new("#{field_name} must be an object", details: { prompt: prompt_name })
      end
      private_class_method :ensure_hash!

      # Calculates the difference between required/allowed arguments and supplied arguments.
      # @api private
      # @param arg_defs [Array<Hash>] The argument definitions for the prompt.
      # @param arguments [Hash] The arguments supplied by the client.
      # @return [Array(Array<String>, Array<String>)] A pair of arrays: [missing_keys, unknown_keys].
      def self.argument_diffs(arg_defs, arguments)
        required = arg_defs.select { |a| a[:required] }.map { |a| a[:name].to_s }
        allowed  = arg_defs.map { |a| a[:name].to_s }

        supplied_keys = arguments.keys.map(&:to_s)

        [required - supplied_keys, supplied_keys - allowed]
      end
      private_class_method :argument_diffs

      # Builds the details hash for an InvalidParamsError related to prompt arguments.
      # @api private
      # @param prompt_name [String] The name of the prompt.
      # @param missing [Array<String>] List of missing required argument names.
      # @param unknown [Array<String>] List of supplied argument names that are not allowed.
      # @return [Hash] The error details hash.
      def self.build_invalid_arg_details(prompt_name, missing, unknown)
        {}.tap do |details|
          details[:prompt]  = prompt_name
          details[:missing] = missing unless missing.empty?
          details[:unknown] = unknown unless unknown.empty?
        end
      end
      private_class_method :build_invalid_arg_details

      # Validates the structure of a prompt handler's response.
      # @api private
      # @param prompt_name [String] The name of the prompt (for error reporting).
      # @param result_data [Object] The data returned by the prompt handler.
      # @param server [VectorMCP::Server] The server instance (for logging).
      # @return [void]
      # @raise [VectorMCP::InternalError] if the response structure is invalid.
      def self.validate_prompt_response!(prompt_name, result_data, server)
        unless result_data.is_a?(Hash) && result_data[:messages].is_a?(Array)
          server.logger.error("Prompt handler for '#{prompt_name}' returned invalid data structure: #{result_data.inspect}")
          raise VectorMCP::InternalError.new("Prompt handler returned invalid data structure",
                                             details: { prompt: prompt_name, error: "Handler must return a Hash with a :messages Array" })
        end

        result_data[:messages].each do |msg|
          next if msg.is_a?(Hash) && msg[:role] && msg[:content].is_a?(Hash) && msg[:content][:type]

          server.logger.error("Prompt handler for '#{prompt_name}' returned invalid message structure: #{msg.inspect}")
          raise VectorMCP::InternalError.new("Prompt handler returned invalid message structure",
                                             details: { prompt: prompt_name,
                                                        error: "Messages must be Hashes with :role and :content Hash (with :type)" })
        end
      end
      private_class_method :validate_prompt_response!

      # Validates arguments provided for a tool against its input schema using json-schema.
      # @api private
      # @param tool_name [String] The name of the tool.
      # @param tool [VectorMCP::Definitions::Tool] The tool definition.
      # @param arguments [Hash] The arguments supplied by the client.
      # @return [void]
      # @raise [VectorMCP::InvalidParamsError] if arguments fail validation.
      def self.validate_input_arguments!(tool_name, tool, arguments)
        return unless tool.input_schema.is_a?(Hash)
        return if tool.input_schema.empty?

        validation_errors = JSON::Validator.fully_validate(tool.input_schema, arguments)
        return if validation_errors.empty?

        raise_tool_validation_error(tool_name, validation_errors)
      rescue JSON::Schema::ValidationError => e
        raise_tool_validation_error(tool_name, [e.message])
      end

      # Raises InvalidParamsError with formatted validation details.
      # @api private
      # @param tool_name [String] The name of the tool.
      # @param validation_errors [Array<String>] The validation error messages.
      # @return [void]
      # @raise [VectorMCP::InvalidParamsError] Always raises with formatted details.
      def self.raise_tool_validation_error(tool_name, validation_errors)
        raise VectorMCP::InvalidParamsError.new(
          "Invalid arguments for tool '#{tool_name}'",
          details: {
            tool: tool_name,
            validation_errors: validation_errors,
            message: validation_errors.join("; ")
          }
        )
      end
      private_class_method :validate_input_arguments!
      private_class_method :raise_tool_validation_error

      # Security helper methods

      # Check security for tool access
      # @api private
      # @param session [VectorMCP::Session] The current session
      # @param tool [VectorMCP::Definitions::Tool] The tool being accessed
      # @param server [VectorMCP::Server] The server instance
      # @return [Hash] Security check result
      def self.check_tool_security(session, tool, server)
        # Extract request context from session for security middleware
        request = extract_request_from_session(session)
        server.security_middleware.process_request(request, action: :call, resource: tool)
      end
      private_class_method :check_tool_security

      # Check security for resource access
      # @api private
      # @param session [VectorMCP::Session] The current session
      # @param resource [VectorMCP::Definitions::Resource] The resource being accessed
      # @param server [VectorMCP::Server] The server instance
      # @return [Hash] Security check result
      def self.check_resource_security(session, resource, server)
        request = extract_request_from_session(session)
        server.security_middleware.process_request(request, action: :read, resource: resource)
      end
      private_class_method :check_resource_security

      # Extract request context from session for security processing
      # @api private
      # @param session [VectorMCP::Session] The current session
      # @return [Hash] Request context for security middleware
      def self.extract_request_from_session(session)
        # All sessions should have a request_context - this is enforced by Session initialization
        unless session.respond_to?(:request_context) && session.request_context
          raise VectorMCP::InternalError,
                "Session missing request_context - transport layer integration error. Session ID: #{session.id}"
        end

        {
          headers: session.request_context.headers,
          params: session.request_context.params,
          session_id: session.id
        }
      end
      private_class_method :extract_request_from_session

      # Handle security failure by raising appropriate error
      # @api private
      # @param security_result [Hash] The security check result
      # @return [void]
      # @raise [VectorMCP::UnauthorizedError, VectorMCP::ForbiddenError]
      def self.handle_security_failure(security_result)
        case security_result[:error_code]
        when "AUTHENTICATION_REQUIRED"
          raise VectorMCP::UnauthorizedError, security_result[:error]
        when "AUTHORIZATION_FAILED"
          raise VectorMCP::ForbiddenError, security_result[:error]
        else
          # Fallback to generic unauthorized error
          raise VectorMCP::UnauthorizedError, security_result[:error] || "Security check failed"
        end
      end
      private_class_method :handle_security_failure

      # Handle middleware error by returning appropriate response or raising error
      # @api private
      # @param context [VectorMCP::Middleware::Context] The middleware context with error
      # @return [Hash, nil] Response hash if middleware provided one
      # @raise [StandardError] Re-raises the original error if not handled
      def self.handle_middleware_error(context)
        # If middleware provided a result, return it
        return context.result if context.result

        # Otherwise, re-raise the middleware error
        raise context.error
      end

      # Tool helper methods

      # Create middleware context for tool operations
      def self.create_tool_context(tool_name, params, session, server)
        VectorMCP::Middleware::Context.new(
          operation_type: :tool_call,
          operation_name: tool_name,
          params: params,
          session: session,
          server: server,
          metadata: { start_time: Time.now }
        )
      end

      # Find and validate tool exists
      def self.find_tool!(tool_name, server)
        tool = server.tools[tool_name]
        raise VectorMCP::NotFoundError.new("Not Found", details: "Tool not found: #{tool_name}") unless tool

        tool
      end

      # Validate tool security
      def self.validate_tool_security!(session, tool, server)
        security_result = check_tool_security(session, tool, server)
        handle_security_failure(security_result) unless security_result[:success]
        security_result
      end

      # Execute tool handler with proper arity handling
      def self.execute_tool_handler(tool, arguments, _security_result, session)
        if [1, -1].include?(tool.handler.arity)
          tool.handler.call(arguments)
        else
          tool.handler.call(arguments, session)
        end
      end

      # Build tool result response
      def self.build_tool_result(result)
        {
          isError: false,
          content: VectorMCP::Util.convert_to_mcp_content(result)
        }
      end

      # Handle tool execution errors
      def self.handle_tool_error(error, context, server)
        context.error = error
        context = server.middleware_manager.execute_hooks(:on_tool_error, context)
        raise error unless context.result

        context.result
      end

      # Resource helper methods

      # Create middleware context for resource operations
      def self.create_resource_context(uri_s, params, session, server)
        VectorMCP::Middleware::Context.new(
          operation_type: :resource_read,
          operation_name: uri_s,
          params: params,
          session: session,
          server: server,
          metadata: { start_time: Time.now }
        )
      end

      # Find and validate resource exists
      def self.find_resource!(uri_s, server)
        raise VectorMCP::NotFoundError.new("Not Found", details: "Resource not found: #{uri_s}") unless server.resources[uri_s]

        server.resources[uri_s]
      end

      # Validate resource security
      def self.validate_resource_security!(session, resource, server)
        security_result = check_resource_security(session, resource, server)
        handle_security_failure(security_result) unless security_result[:success]
        security_result
      end

      # Execute resource handler with proper arity handling
      def self.execute_resource_handler(resource, params, security_result)
        if [1, -1].include?(resource.handler.arity)
          resource.handler.call(params)
        else
          resource.handler.call(params, security_result[:session_context])
        end
      end

      # Process resource content and add URI
      def self.process_resource_content(content_raw, resource, uri_s)
        contents = VectorMCP::Util.convert_to_mcp_content(content_raw, mime_type: resource.mime_type)
        contents.each do |item|
          item[:uri] ||= uri_s
        end
        contents
      end

      # Handle resource execution errors
      def self.handle_resource_error(error, context, server)
        context.error = error
        context = server.middleware_manager.execute_hooks(:on_resource_error, context)
        raise error unless context.result

        context.result
      end

      private_class_method :handle_middleware_error, :create_tool_context, :find_tool!, :validate_tool_security!,
                           :execute_tool_handler, :build_tool_result, :handle_tool_error, :create_resource_context,
                           :find_resource!, :validate_resource_security!, :execute_resource_handler,
                           :process_resource_content, :handle_resource_error
    end
  end
end
