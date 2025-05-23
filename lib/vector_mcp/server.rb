# frozen_string_literal: true

require "English"
require "logger"
require_relative "definitions"
require_relative "session"
require_relative "errors"
require_relative "transport/stdio" # Default transport
# require_relative "transport/sse" # Load on demand to avoid async dependencies
require_relative "handlers/core" # Default handlers
require_relative "util" # Needed if not using Handlers::Core

module VectorMCP
  # The `Server` class is the central component for an MCP server implementation.
  # It manages tools, resources, prompts, and handles the MCP message lifecycle.
  #
  # A server instance is typically initialized, configured with capabilities (tools,
  # resources, prompts), and then run with a chosen transport mechanism (e.g., Stdio, SSE).
  #
  # @example Creating and running a simple server
  #   server = VectorMCP::Server.new(name: "MySimpleServer", version: "1.0")
  #
  #   server.register_tool(
  #     name: "echo",
  #     description: "Echoes back the input string.",
  #     input_schema: { type: "object", properties: { message: { type: "string" } } }
  #   ) do |args|
  #     args["message"]
  #   end
  #
  #   server.run(transport: :stdio) # Runs with Stdio transport by default
  #
  # @!attribute [r] logger
  #   @return [Logger] The logger instance for this server.
  # @!attribute [r] name
  #   @return [String] The name of the server.
  # @!attribute [r] version
  #   @return [String] The version of the server software.
  # @!attribute [r] protocol_version
  #   @return [String] The MCP protocol version this server implements.
  # @!attribute [r] tools
  #   @return [Hash<String, VectorMCP::Definitions::Tool>] Registered tools, keyed by name.
  # @!attribute [r] resources
  #   @return [Hash<String, VectorMCP::Definitions::Resource>] Registered resources, keyed by URI string.
  # @!attribute [r] prompts
  #   @return [Hash<String, VectorMCP::Definitions::Prompt>] Registered prompts, keyed by name.
  # @!attribute [r] roots
  #   @return [Hash<String, VectorMCP::Definitions::Root>] Registered roots, keyed by URI string.
  # @!attribute [r] in_flight_requests
  #   @return [Hash] A hash tracking currently processing requests, for cancellation purposes.
  # @!attribute [rw] transport
  #   @return [VectorMCP::Transport::Base, nil] The active transport instance, if any.
  class Server
    include Definitions # Make Tool, Resource, Prompt, Root structs easily available

    # The specific version of the Model Context Protocol this server implements.
    PROTOCOL_VERSION = "2024-11-05"

    attr_reader :logger, :name, :version, :protocol_version, :tools, :resources, :prompts, :roots, :in_flight_requests
    attr_accessor :transport

    # Initializes a new VectorMCP server.
    #
    # @param name_pos [String] Positional name argument (deprecated, use name: instead).
    # @param name [String] The name of the server.
    # @param version [String] The version of the server.
    # @param log_level [Integer] The logging level (Logger::DEBUG, Logger::INFO, etc.).
    # @param protocol_version [String] The MCP protocol version to use.
    # @param sampling_config [Hash] Configuration for sampling capabilities. Available options:
    #   - :enabled [Boolean] Whether sampling is enabled (default: true)
    #   - :methods [Array<String>] Supported sampling methods (default: ["createMessage"])
    #   - :supports_streaming [Boolean] Whether streaming is supported (default: false)
    #   - :supports_tool_calls [Boolean] Whether tool calls are supported (default: false)
    #   - :supports_images [Boolean] Whether image content is supported (default: false)
    #   - :max_tokens_limit [Integer, nil] Maximum tokens limit (default: nil, no limit)
    #   - :timeout_seconds [Integer] Default timeout for sampling requests (default: 30)
    #   - :context_inclusion_methods [Array<String>] Supported context inclusion methods
    #     (default: ["none", "thisServer"])
    #   - :model_preferences_supported [Boolean] Whether model preferences are supported (default: true)
    def initialize(name_pos = nil, *, name: nil, version: "0.1.0", log_level: Logger::INFO, protocol_version: PROTOCOL_VERSION, sampling_config: {})
      raise ArgumentError, "Name provided both positionally (#{name_pos}) and as keyword argument (#{name})" if name_pos && name && name_pos != name

      @name = name_pos || name || "UnnamedServer"
      @version = version
      @protocol_version = protocol_version
      @logger = VectorMCP.logger
      @logger.level = log_level if log_level

      @transport = nil
      @tools = {}
      @resources = {}
      @prompts = {}
      @roots = {}
      @request_handlers = {}
      @notification_handlers = {}
      @in_flight_requests = {}
      @prompts_list_changed = false
      @prompt_subscribers = []
      @roots_list_changed = false

      # Configure sampling capabilities
      @sampling_config = configure_sampling_capabilities(sampling_config)

      setup_default_handlers

      @logger.info("Server instance '#{@name}' v#{@version} (MCP Protocol: #{@protocol_version}, Gem: v#{VectorMCP::VERSION}) initialized.")
    end

    # --- Registration Methods ---

    # Registers a new tool with the server.
    #
    # @param name [String, Symbol] The unique name for the tool.
    # @param description [String] A human-readable description of the tool.
    # @param input_schema [Hash] A JSON Schema object that precisely describes the
    #   structure of the argument hash your tool expects.  The schema **must** be
    #   compatible with the official MCP JSON-Schema draft so that remote
    #   validators can verify user input.
    # @yield [Hash] A block implementing the tool logic.  The yielded argument is
    #   the user-supplied input hash, already guaranteed (by the caller) to match
    #   `input_schema`.
    # @return [self] Returns the server instance so you can chain
    #   registrations—e.g., `server.register_tool(...).register_resource(...)`.
    # @raise [ArgumentError] If another tool with the same name is already registered.
    def register_tool(name:, description:, input_schema:, &handler)
      name_s = name.to_s
      raise ArgumentError, "Tool '#{name_s}' already registered" if @tools[name_s]

      @tools[name_s] = Tool.new(name_s, description, input_schema, handler)
      logger.debug("Registered tool: #{name_s}")
      self
    end

    # Registers a new resource with the server.
    #
    # @param uri [String, URI] The unique URI for the resource.
    # @param name [String] A human-readable name for the resource.
    # @param description [String] A description of the resource.
    # @param mime_type [String] The MIME type of the resource's content (default: "text/plain").
    # @yield [Hash] A block that provides the resource's content. It may receive parameters
    #   from the `resources/read` request (for dynamic resources; for static resources, parameters may be ignored).
    #   The block should return **any Ruby value**; the value will be normalised
    #   to MCP `Content[]` via {VectorMCP::Util.convert_to_mcp_content}.
    # @return [self] The server instance, for chaining.
    # @raise [ArgumentError] if a resource with the same URI is already registered.
    def register_resource(uri:, name:, description:, mime_type: "text/plain", &handler)
      uri_s = uri.to_s
      raise ArgumentError, "Resource '#{uri_s}' already registered" if @resources[uri_s]

      @resources[uri_s] = Resource.new(uri, name, description, mime_type, handler)
      logger.debug("Registered resource: #{uri_s}")
      self
    end

    # Registers a new prompt with the server.
    #
    # @param name [String, Symbol] The unique name for the prompt.
    # @param description [String] A human-readable description of the prompt.
    # @param arguments [Array<Hash>] An array defining the prompt's arguments.
    #   Each hash should conform to the prompt argument schema (e.g., `{ name:, description:, required: }`).
    # @yield [Hash] A block that generates the prompt. It receives a hash of arguments,
    #   validated against the prompt's argument definitions. The block must
    #   return a hash conforming to the MCP *GetPromptResult* schema—see
    #   Handlers::Core#get_prompt for the exact contract enforced.
    # @return [self] The server instance, for chaining.
    # @raise [ArgumentError] if a prompt with the same name is already registered, or if
    #   the `arguments` definition is invalid.
    def register_prompt(name:, description:, arguments: [], &handler)
      name_s = name.to_s
      raise ArgumentError, "Prompt '#{name_s}' already registered" if @prompts[name_s]

      validate_prompt_arguments(arguments)
      @prompts[name_s] = Prompt.new(name_s, description, arguments, handler)
      @prompts_list_changed = true
      notify_prompts_list_changed
      logger.debug("Registered prompt: #{name_s}")
      self
    end

    # Registers a new root with the server.
    #
    # @param uri [String, URI] The unique URI for the root (must be file:// scheme).
    # @param name [String] A human-readable name for the root.
    # @return [self] The server instance, for chaining.
    # @raise [ArgumentError] if a root with the same URI is already registered, or if
    #   the URI is invalid.
    #
    # @example Register a project directory as a root
    #   server.register_root(
    #     uri: "file:///home/user/projects/myapp",
    #     name: "My Application"
    #   )
    #
    # @example Register multiple roots for a workspace
    #   server.register_root(uri: "file:///home/user/frontend", name: "Frontend")
    #         .register_root(uri: "file:///home/user/backend", name: "Backend")
    def register_root(uri:, name:)
      uri_s = uri.to_s
      raise ArgumentError, "Root '#{uri_s}' already registered" if @roots[uri_s]

      root = Root.new(uri, name)
      root.validate! # This will raise ArgumentError if invalid

      @roots[uri_s] = root
      @roots_list_changed = true
      notify_roots_list_changed
      logger.debug("Registered root: #{uri_s} (#{name})")
      self
    end

    # Helper method to register a root from a local directory path.
    #
    # @param path [String] Local filesystem path to the directory.
    # @param name [String, nil] Human-readable name for the root. If nil, uses directory basename.
    # @return [self] The server instance, for chaining.
    # @raise [ArgumentError] if the path is invalid or not accessible.
    #
    # @example Register current directory as a root
    #   server.register_root_from_path(".", name: "Current Project")
    #
    # @example Register multiple project directories
    #   server.register_root_from_path("/home/user/projects/frontend")
    #         .register_root_from_path("/home/user/projects/backend")
    def register_root_from_path(path, name: nil)
      root = Root.from_path(path, name: name)
      register_root(uri: root.uri, name: root.name)
    end

    # --- Request/Notification Hook Methods ---

    # Registers a handler for a specific JSON-RPC request method.
    #
    # @param method [String, Symbol] The method name (e.g., "my/customMethod").
    # @yield [params, session, server] A block to handle the request.
    #   - `params` [Hash]: The request parameters.
    #   - `session` [VectorMCP::Session]: The current client session.
    #   - `server` [VectorMCP::Server]: The server instance itself.
    #   The block should return the result for the JSON-RPC response.
    # @return [self] The server instance.
    def on_request(method, &handler)
      @request_handlers[method.to_s] = handler
      self
    end

    # Registers a handler for a specific JSON-RPC notification method.
    #
    # @param method [String, Symbol] The method name (e.g., "my/customNotification").
    # @yield [params, session, server] A block to handle the notification.
    #   (Parameters are the same as for `on_request`.)
    # @return [self] The server instance.
    def on_notification(method, &handler)
      @notification_handlers[method.to_s] = handler
      self
    end

    # --- Server Execution ---

    # Runs the server using the specified transport mechanism.
    #
    # @param transport [:stdio, :sse, VectorMCP::Transport::Base] The transport to use.
    #   Can be a symbol (`:stdio`, `:sse`) or an initialized transport instance.
    #   If a symbol is provided, the method will instantiate the corresponding transport class.
    #   If `:sse` is chosen, ensure `async` and `falcon` gems are available.
    # @param options [Hash] Transport-specific options (e.g., `:host`, `:port` for SSE).
    #   These are passed to the transport's constructor if a symbol is provided for `transport`.
    # @return [void]
    # @raise [ArgumentError] if an unsupported transport symbol is given.
    # @raise [NotImplementedError] if `:sse` transport is specified (currently a placeholder).
    def run(transport: :stdio, **options)
      active_transport = case transport
                         when :stdio
                           VectorMCP::Transport::Stdio.new(self, **options)
                         when :sse
                           begin
                             require_relative "transport/sse"
                             VectorMCP::Transport::SSE.new(self, **options)
                           rescue LoadError => e
                             logger.fatal("SSE transport requires additional dependencies. Install the 'async' and 'falcon' gems.")
                             raise NotImplementedError, "SSE transport dependencies not available: #{e.message}"
                           end
                         when VectorMCP::Transport::Base # Allow passing an initialized transport instance
                           transport.server = self if transport.respond_to?(:server=) && transport.server.nil? # Ensure server is set
                           transport
                         else
                           logger.fatal("Unsupported transport type: #{transport.inspect}")
                           raise ArgumentError, "Unsupported transport: #{transport.inspect}"
                         end
      self.transport = active_transport
      active_transport.run
    end

    # --- Message Handling Logic (primarily called by transports) ---

    # Handles an incoming JSON-RPC message (request or notification).
    # This is the main dispatch point for messages received by a transport.
    #
    # @param message [Hash] The parsed JSON-RPC message object.
    # @param session [VectorMCP::Session] The client session associated with this message.
    # @param session_id [String] A unique identifier for the underlying transport connection (e.g., socket ID, stdio pipe).
    # @return [Object, nil] For requests, returns the result data to be sent in the JSON-RPC response.
    #   For notifications, returns `nil`.
    # @raise [VectorMCP::ProtocolError] if the message is invalid or an error occurs during handling
    #   that should be reported as a JSON-RPC error. May also raise subclasses such as NotFoundError, InvalidParamsError, etc.
    def handle_message(message, session, session_id)
      id = message["id"]
      method = message["method"]
      params = message["params"] || {} # Default to empty hash if params is nil

      if id && method # Request
        logger.info("[#{session_id}] Request [#{id}]: #{method} with params: #{params.inspect}")
        handle_request(id, method, params, session)
      elsif method # Notification
        logger.info("[#{session_id}] Notification: #{method} with params: #{params.inspect}")
        handle_notification(method, params, session)
        nil # Notifications do not have a return value to send back to client
      elsif id # Invalid: Has ID but no method (likely a malformed request or client sending a response)
        logger.warn("[#{session_id}] Invalid message: Has ID [#{id}] but no method. #{message.inspect}")
        raise VectorMCP::InvalidRequestError.new("Request object must include a 'method' member.", request_id: id)
      else # Invalid: No ID and no method
        logger.warn("[#{session_id}] Invalid message: Missing both 'id' and 'method'. #{message.inspect}")
        raise VectorMCP::InvalidRequestError.new("Invalid message format", request_id: nil)
      end
    end

    # --- Server Information and Capabilities ---

    # Provides basic information about the server.
    # @return [Hash] Server name and version.
    def server_info
      { name: @name, version: @version }
    end

    # Returns the sampling configuration for this server.
    # @return [Hash] The sampling configuration including capabilities and limits.
    def sampling_config
      @sampling_config[:config]
    end

    # Describes the capabilities of this server according to MCP specifications.
    # @return [Hash] A capabilities object.
    def server_capabilities
      caps = {}
      caps[:tools] = { listChanged: false } unless @tools.empty? # `listChanged` for tools is not standard but included for symmetry
      caps[:resources] = { subscribe: false, listChanged: false } unless @resources.empty?
      caps[:prompts] = { listChanged: @prompts_list_changed } unless @prompts.empty?
      caps[:roots] = { listChanged: true } unless @roots.empty? # Always support list change notifications for roots
      caps[:sampling] = @sampling_config[:capabilities] # Detailed sampling capabilities
      # `experimental` is a defined field in MCP capabilities, can be used for non-standard features.
      caps
    end

    # Resets the `prompts_list_changed` flag to false.
    # Typically called by the `prompts/list` handler after a client has fetched the updated list.
    # @return [void]
    def clear_prompts_list_changed
      @prompts_list_changed = false
      logger.debug("Prompts listChanged flag cleared.")
    end

    # Notifies connected clients that the list of available prompts has changed.
    # This method attempts to use `broadcast_notification` if the transport supports it,
    # otherwise falls back to `send_notification` (which might only make sense for single-client transports like stdio).
    # @return [void]
    def notify_prompts_list_changed
      return unless transport && @prompts_list_changed # Only notify if there was a change and transport is up

      notification_method = "notifications/prompts/list_changed"
      begin
        if transport.respond_to?(:broadcast_notification)
          logger.info("Broadcasting prompts list changed notification.")
          transport.broadcast_notification(notification_method)
        elsif transport.respond_to?(:send_notification)
          # For single-client transports or as a fallback if broadcast isn't specific
          logger.info("Sending prompts list changed notification (transport may broadcast or send to first client).")
          transport.send_notification(notification_method) # Transport needs to decide target if not broadcast
        else
          logger.warn("Transport does not support sending notifications/prompts/list_changed.")
        end
      rescue StandardError => e
        logger.error("Failed to send prompts list changed notification: #{e.class.name}: #{e.message}")
      end
    end

    # Resets the `roots_list_changed` flag to false.
    # Typically called by the `roots/list` handler after a client has fetched the updated list.
    # @return [void]
    def clear_roots_list_changed
      @roots_list_changed = false
      logger.debug("Roots listChanged flag cleared.")
    end

    # Notifies connected clients that the list of available roots has changed.
    # This method attempts to use `broadcast_notification` if the transport supports it,
    # otherwise falls back to `send_notification` (which might only make sense for single-client transports like stdio).
    # @return [void]
    def notify_roots_list_changed
      return unless transport && @roots_list_changed # Only notify if there was a change and transport is up

      notification_method = "notifications/roots/list_changed"
      begin
        if transport.respond_to?(:broadcast_notification)
          logger.info("Broadcasting roots list changed notification.")
          transport.broadcast_notification(notification_method)
        elsif transport.respond_to?(:send_notification)
          # For single-client transports or as a fallback if broadcast isn't specific
          logger.info("Sending roots list changed notification (transport may broadcast or send to first client).")
          transport.send_notification(notification_method) # Transport needs to decide target if not broadcast
        else
          logger.warn("Transport does not support sending notifications/roots/list_changed.")
        end
      rescue StandardError => e
        logger.error("Failed to send roots list changed notification: #{e.class.name}: #{e.message}")
      end
    end

    # Helper method to register an image resource from a file path.
    #
    # @param uri [String] Unique URI for the resource.
    # @param file_path [String] Path to the image file.
    # @param name [String, nil] Human-readable name (auto-generated if nil).
    # @param description [String, nil] Description (auto-generated if nil).
    # @return [VectorMCP::Definitions::Resource] The registered resource.
    # @raise [ArgumentError] If the file doesn't exist or isn't a valid image.
    #
    # @example Register an image resource
    #   server.register_image_resource(
    #     uri: "images://logo.png",
    #     file_path: "./assets/logo.png",
    #     name: "Company Logo"
    #   )
    def register_image_resource(uri:, file_path:, name: nil, description: nil)
      resource = VectorMCP::Definitions::Resource.from_image_file(
        uri: uri,
        file_path: file_path,
        name: name,
        description: description
      )

      register_resource(
        uri: resource.uri,
        name: resource.name,
        description: resource.description,
        mime_type: resource.mime_type,
        &resource.handler
      )
    end

    # Helper method to register an image resource from binary data.
    #
    # @param uri [String] Unique URI for the resource.
    # @param image_data [String] Binary image data.
    # @param name [String] Human-readable name.
    # @param description [String, nil] Description (auto-generated if nil).
    # @param mime_type [String, nil] MIME type (auto-detected if nil).
    # @return [VectorMCP::Definitions::Resource] The registered resource.
    # @raise [ArgumentError] If the data isn't valid image data.
    #
    # @example Register an image resource from data
    #   image_data = generate_chart_image()
    #   server.register_image_resource_from_data(
    #     uri: "charts://sales-2024.png",
    #     image_data: image_data,
    #     name: "Sales Chart 2024",
    #     mime_type: "image/png"
    #   )
    def register_image_resource_from_data(uri:, image_data:, name:, description: nil, mime_type: nil)
      resource = VectorMCP::Definitions::Resource.from_image_data(
        uri: uri,
        image_data: image_data,
        name: name,
        description: description,
        mime_type: mime_type
      )

      register_resource(
        uri: resource.uri,
        name: resource.name,
        description: resource.description,
        mime_type: resource.mime_type,
        &resource.handler
      )
    end

    # Helper method to register a tool that accepts image inputs.
    #
    # @param name [String] Unique name for the tool.
    # @param description [String] Human-readable description.
    # @param image_parameter [String] Name of the image parameter (default: "image").
    # @param additional_parameters [Hash] Additional JSON Schema properties.
    # @param required_parameters [Array<String>] List of required parameter names.
    # @param block [Proc] The tool handler block.
    # @return [VectorMCP::Definitions::Tool] The registered tool.
    #
    # @example Register an image analysis tool
    #   server.register_image_tool(
    #     name: "analyze_image",
    #     description: "Analyzes an image and returns metadata",
    #     image_parameter: "image_data",
    #     additional_parameters: {
    #       format: { type: "string", enum: ["summary", "detailed"], default: "summary" }
    #     },
    #     required_parameters: ["image_data"]
    #   ) do |args, session|
    #     image_content = args["image_data"]
    #     # Process the image...
    #     { analysis: "Image contains...", format: args["format"] }
    #   end
    def register_image_tool(name:, description:, image_parameter: "image", additional_parameters: {}, required_parameters: [], &block)
      # Build the input schema with image support
      image_property = {
        type: "string",
        description: "Base64 encoded image data or file path to image",
        contentEncoding: "base64",
        contentMediaType: "image/*"
      }

      properties = { image_parameter => image_property }.merge(additional_parameters)

      input_schema = {
        type: "object",
        properties: properties,
        required: required_parameters
      }

      register_tool(
        name: name,
        description: description,
        input_schema: input_schema,
        &block
      )
    end

    # Helper method to register a prompt that supports image arguments.
    #
    # @param name [String] Unique name for the prompt.
    # @param description [String] Human-readable description.
    # @param image_argument [String] Name of the image argument (default: "image").
    # @param additional_arguments [Array<Hash>] Additional prompt arguments.
    # @param block [Proc] The prompt handler block.
    # @return [VectorMCP::Definitions::Prompt] The registered prompt.
    #
    # @example Register an image description prompt
    #   server.register_image_prompt(
    #     name: "describe_image",
    #     description: "Generate a detailed description of an image",
    #     additional_arguments: [
    #       { name: "style", description: "Description style", required: false }
    #     ]
    #   ) do |args, session|
    #     image_path = args["image"]
    #     style = args["style"] || "detailed"
    #     # Generate prompt with image...
    #   end
    def register_image_prompt(name:, description:, image_argument: "image", additional_arguments: [], &block)
      prompt = VectorMCP::Definitions::Prompt.with_image_support(
        name: name,
        description: description,
        image_argument_name: image_argument,
        additional_arguments: additional_arguments,
        &block
      )

      register_prompt(
        name: prompt.name,
        description: prompt.description,
        arguments: prompt.arguments,
        &prompt.handler
      )
    end

    private

    # Configures sampling capabilities based on provided configuration.
    # @api private
    # @param config [Hash] Sampling configuration options.
    # @return [Hash] The configured sampling capabilities.
    def configure_sampling_capabilities(config)
      defaults = {
        enabled: true,
        methods: ["createMessage"],
        supports_streaming: false,
        supports_tool_calls: false,
        supports_images: false,
        max_tokens_limit: nil,
        timeout_seconds: 30,
        context_inclusion_methods: %w[none thisServer],
        model_preferences_supported: true
      }

      resolved_config = defaults.merge(config.transform_keys(&:to_sym))

      # Build MCP-compliant capabilities object
      capabilities = {}

      if resolved_config[:enabled]
        capabilities[:methods] = resolved_config[:methods]
        capabilities[:features] = build_sampling_features(resolved_config)
        capabilities[:limits] = build_sampling_limits(resolved_config)
        capabilities[:contextInclusion] = resolved_config[:context_inclusion_methods]
      end

      {
        config: resolved_config,
        capabilities: capabilities
      }
    end

    # Builds the features section of sampling capabilities.
    # @api private
    def build_sampling_features(config)
      features = {}
      features[:streaming] = true if config[:supports_streaming]
      features[:toolCalls] = true if config[:supports_tool_calls]
      features[:images] = true if config[:supports_images]
      features[:modelPreferences] = true if config[:model_preferences_supported]
      features
    end

    # Builds the limits section of sampling capabilities.
    # @api private
    def build_sampling_limits(config)
      limits = {}
      limits[:maxTokens] = config[:max_tokens_limit] if config[:max_tokens_limit]
      limits[:defaultTimeout] = config[:timeout_seconds] if config[:timeout_seconds]
      limits
    end

    # Registers a session as a subscriber to prompt list changes.
    # Used by the `prompts/subscribe` handler.
    # @api private
    # @param session [VectorMCP::Session] The session to subscribe.
    # @return [void]
    def subscribe_prompts(session)
      @prompt_subscribers << session unless @prompt_subscribers.include?(session)
      logger.debug("Session subscribed to prompt list changes: #{session.object_id}")
    end

    # Internal handler for JSON-RPC requests.
    # @api private
    # @param id [String, Integer] The request ID.
    # @param method [String] The request method name.
    # @param params [Hash] The request parameters.
    # @param session [VectorMCP::Session] The client session.
    # @return [Object] The result of the request handler.
    # @raise [VectorMCP::ProtocolError] Propagates errors from handlers or raises new ones (e.g., MethodNotFound, NotFoundError, etc.).
    # rubocop:disable Metrics/MethodLength
    def handle_request(id, method, params, session)
      unless session.initialized?
        # Allow "initialize" even if not marked initialized yet by server
        return session.initialize!(params) if method == "initialize"

        # For any other method, session must be initialized
        raise VectorMCP::InitializationError.new("Session not initialized. Client must send 'initialize' first.", request_id: id)
      end

      handler = @request_handlers[method]
      raise VectorMCP::MethodNotFoundError.new(method, request_id: id) unless handler

      begin
        @in_flight_requests[id] = { method: method, params: params, session: session, start_time: Time.now }
        result = handler.call(params, session, self)
        result
      rescue VectorMCP::ProtocolError => e # Includes NotFoundError, InvalidParamsError, InternalError from handlers
        # Ensure the request ID from the current context is on the error
        e.request_id = id unless e.request_id && e.request_id == id
        raise e # Re-raise with potentially updated request_id
      rescue StandardError => e
        logger.error("Unhandled error during request '#{method}' (ID: #{id}): #{e.message}\nBacktrace: #{e.backtrace.join("\n  ")}")
        raise VectorMCP::InternalError.new(
          "Request handler failed unexpectedly",
          request_id: id,
          details: { method: method, error: "An internal error occurred" }
        )
      ensure
        @in_flight_requests.delete(id)
      end
    end
    # rubocop:enable Metrics/MethodLength

    # Internal handler for JSON-RPC notifications.
    # @api private
    # @param method [String] The notification method name.
    # @param params [Hash] The notification parameters.
    # @param session [VectorMCP::Session] The client session.
    # @return [void]
    # @raise [StandardError] if the notification handler raises an error (errors are logged, not propagated to the client).
    def handle_notification(method, params, session)
      unless session.initialized? || method == "initialized"
        logger.warn("Ignoring notification '#{method}' before session is initialized. Params: #{params.inspect}")
        return
      end

      handler = @notification_handlers[method]
      if handler
        begin
          handler.call(params, session, self)
        rescue StandardError => e
          logger.error("Error executing notification handler '#{method}': #{e.message}\nBacktrace (top 5):\n  #{e.backtrace.first(5).join("\n  ")}")
          # Notifications must not generate a response, even on error.
        end
      else
        logger.debug("No handler registered for notification: #{method}")
      end
    end

    # Sets up default handlers for core MCP methods using {VectorMCP::Handlers::Core}.
    # @api private
    # @return [void]
    def setup_default_handlers
      # Core Requests
      on_request("initialize", &session_method(:initialize!))
      on_request("ping", &Handlers::Core.method(:ping))
      on_request("tools/list", &Handlers::Core.method(:list_tools))
      on_request("tools/call", &Handlers::Core.method(:call_tool))
      on_request("resources/list", &Handlers::Core.method(:list_resources))
      on_request("resources/read", &Handlers::Core.method(:read_resource))
      on_request("prompts/list", &Handlers::Core.method(:list_prompts))
      on_request("prompts/get", &Handlers::Core.method(:get_prompt))
      on_request("prompts/subscribe", &Handlers::Core.method(:subscribe_prompts))
      on_request("roots/list", &Handlers::Core.method(:list_roots))

      # Core Notifications
      on_notification("initialized", &Handlers::Core.method(:initialized_notification))
      # Standard cancel request names
      %w[$/cancelRequest $/cancel notifications/cancelled].each do |cancel_method|
        on_notification(cancel_method, &Handlers::Core.method(:cancel_request_notification))
      end
    end

    # Helper to create a proc that calls a method on the session object.
    # Used for the `initialize` request handler.
    # @api private
    def session_method(method_name)
      lambda do |params, session, _server|
        session.public_send(method_name, params)
      end
    end

    # Validates the structure of the `arguments` array provided to {#register_prompt}.
    # Each item must be a Hash with at least a `:name`, and optionally `:description` and `:required`.
    # @api private
    # @param argument_defs [Array<Hash>] The array of argument definitions to validate.
    # @return [void]
    # @raise [ArgumentError] if `argument_defs` is not an Array or if any definition is invalid.
    def validate_prompt_arguments(argument_defs)
      raise ArgumentError, "Prompt arguments definition must be an Array of Hashes." unless argument_defs.is_a?(Array)

      argument_defs.each_with_index { |arg, idx| validate_single_prompt_argument(arg, idx) }
    end

    # Defines the keys allowed in a prompt argument definition hash.
    ALLOWED_PROMPT_ARG_KEYS = %w[name description required type].freeze # Added 'type' as per common usage
    private_constant :ALLOWED_PROMPT_ARG_KEYS

    # Validates a single prompt argument definition hash.
    # @api private
    # @param arg [Hash] The argument definition hash.
    # @param idx [Integer] The index of this argument in the list (for error messages).
    # @return [void]
    # @raise [ArgumentError] if the argument definition is invalid.
    def validate_single_prompt_argument(arg, idx)
      raise ArgumentError, "Prompt argument definition at index #{idx} must be a Hash. Found: #{arg.class}" unless arg.is_a?(Hash)

      validate_prompt_arg_name!(arg, idx)
      validate_prompt_arg_description!(arg, idx)
      validate_prompt_arg_required_flag!(arg, idx)
      validate_prompt_arg_type!(arg, idx) # New validation for :type
      validate_prompt_arg_unknown_keys!(arg, idx)
    end

    # Validates the :name key of a prompt argument definition.
    # @api private
    def validate_prompt_arg_name!(arg, idx)
      name_val = arg[:name] || arg["name"]
      raise ArgumentError, "Prompt argument at index #{idx} missing :name" if name_val.nil?
      unless name_val.is_a?(String) || name_val.is_a?(Symbol)
        raise ArgumentError, "Prompt argument :name at index #{idx} must be a String or Symbol. Found: #{name_val.class}"
      end
      raise ArgumentError, "Prompt argument :name at index #{idx} cannot be empty." if name_val.to_s.strip.empty?
    end

    # Validates the :description key of a prompt argument definition.
    # @api private
    def validate_prompt_arg_description!(arg, idx)
      return unless arg.key?(:description) || arg.key?("description") # Optional field

      desc_val = arg[:description] || arg["description"]
      return if desc_val.nil? || desc_val.is_a?(String) # Allow nil or String

      raise ArgumentError, "Prompt argument :description at index #{idx} must be a String if provided. Found: #{desc_val.class}"
    end

    # Validates the :required key of a prompt argument definition.
    # @api private
    def validate_prompt_arg_required_flag!(arg, idx)
      return unless arg.key?(:required) || arg.key?("required") # Optional field

      req_val = arg[:required] || arg["required"]
      return if [true, false].include?(req_val)

      raise ArgumentError, "Prompt argument :required at index #{idx} must be true or false if provided. Found: #{req_val.inspect}"
    end

    # Validates the :type key of a prompt argument definition (new).
    # @api private
    def validate_prompt_arg_type!(arg, idx)
      return unless arg.key?(:type) || arg.key?("type") # Optional field

      type_val = arg[:type] || arg["type"]
      return if type_val.nil? || type_val.is_a?(String) # Allow nil or String (e.g., "string", "number", "boolean")

      raise ArgumentError, "Prompt argument :type at index #{idx} must be a String if provided (e.g., JSON schema type). Found: #{type_val.class}"
    end

    # Checks for any unknown keys in a prompt argument definition.
    # @api private
    def validate_prompt_arg_unknown_keys!(arg, idx)
      unknown_keys = arg.transform_keys(&:to_s).keys - ALLOWED_PROMPT_ARG_KEYS
      return if unknown_keys.empty?

      # rubocop:disable Layout/LineLength
      raise ArgumentError,
            "Prompt argument definition at index #{idx} contains unknown keys: #{unknown_keys.join(", ")}. Allowed: #{ALLOWED_PROMPT_ARG_KEYS.join(", ")}."
      # rubocop:enable Layout/LineLength
    end
  end

  module Transport
    # Dummy base class placeholder used only for argument validation in tests.
    # Real transport classes (e.g., Stdio, SSE) are separate concrete classes.
    class Base # :nodoc:
    end
  end
end
