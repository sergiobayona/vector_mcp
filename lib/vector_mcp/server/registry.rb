# frozen_string_literal: true

require "json-schema"

module VectorMCP
  class Server
    # Handles registration of tools, resources, prompts, and roots
    module Registry
      # --- Registration Methods ---

      # Registers a new tool with the server.
      #
      # @param name [String, Symbol] The unique name for the tool.
      # @param description [String] A human-readable description of the tool.
      # @param input_schema [Hash] A JSON Schema object that precisely describes the
      #   structure of the argument hash your tool expects.
      # @yield [Hash] A block implementing the tool logic.
      # @return [self] Returns the server instance so you can chain registrations.
      # @raise [ArgumentError] If another tool with the same name is already registered.
      def register_tool(name:, description:, input_schema:, &handler)
        name_s = name.to_s
        raise ArgumentError, "Tool '#{name_s}' already registered" if @tools[name_s]

        # Validate schema format during registration
        validate_schema_format!(input_schema) if input_schema

        @tools[name_s] = VectorMCP::Definitions::Tool.new(name_s, description, input_schema, handler)
        logger.debug("Registered tool: #{name_s}")
        self
      end

      # Registers a new resource with the server.
      #
      # @param uri [String, URI] The unique URI for the resource.
      # @param name [String] A human-readable name for the resource.
      # @param description [String] A description of the resource.
      # @param mime_type [String] The MIME type of the resource's content (default: "text/plain").
      # @yield [Hash] A block that provides the resource's content.
      # @return [self] The server instance, for chaining.
      # @raise [ArgumentError] if a resource with the same URI is already registered.
      def register_resource(uri:, name:, description:, mime_type: "text/plain", &handler)
        uri_s = uri.to_s
        raise ArgumentError, "Resource '#{uri_s}' already registered" if @resources[uri_s]

        @resources[uri_s] = VectorMCP::Definitions::Resource.new(uri, name, description, mime_type, handler)
        logger.debug("Registered resource: #{uri_s}")
        self
      end

      # Registers a new prompt with the server.
      #
      # @param name [String, Symbol] The unique name for the prompt.
      # @param description [String] A human-readable description of the prompt.
      # @param arguments [Array<Hash>] An array defining the prompt's arguments.
      # @yield [Hash] A block that generates the prompt.
      # @return [self] The server instance, for chaining.
      # @raise [ArgumentError] if a prompt with the same name is already registered.
      def register_prompt(name:, description:, arguments: [], &handler)
        name_s = name.to_s
        raise ArgumentError, "Prompt '#{name_s}' already registered" if @prompts[name_s]

        validate_prompt_arguments(arguments)
        @prompts[name_s] = VectorMCP::Definitions::Prompt.new(name_s, description, arguments, handler)
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
      # @raise [ArgumentError] if a root with the same URI is already registered.
      def register_root(uri:, name:)
        uri_s = uri.to_s
        raise ArgumentError, "Root '#{uri_s}' already registered" if @roots[uri_s]

        root = VectorMCP::Definitions::Root.new(uri, name)
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
      # @param name [String, nil] Human-readable name for the root.
      # @return [self] The server instance, for chaining.
      # @raise [ArgumentError] if the path is invalid or not accessible.
      def register_root_from_path(path, name: nil)
        root = VectorMCP::Definitions::Root.from_path(path, name: name)
        register_root(uri: root.uri, name: root.name)
      end

      # Helper method to register an image resource from a file path.
      #
      # @param uri [String] Unique URI for the resource.
      # @param file_path [String] Path to the image file.
      # @param name [String, nil] Human-readable name (auto-generated if nil).
      # @param description [String, nil] Description (auto-generated if nil).
      # @return [VectorMCP::Definitions::Resource] The registered resource.
      # @raise [ArgumentError] If the file doesn't exist or isn't a valid image.
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

      # Validates that the provided schema is a valid JSON Schema.
      # @api private
      # @param schema [Hash, nil] The JSON Schema to validate.
      # @return [void]
      # @raise [ArgumentError] if the schema is invalid.
      def validate_schema_format!(schema)
        return if schema.nil? || schema.empty?
        return unless schema.is_a?(Hash)

        # Use JSON::Validator to validate the schema format itself
        validation_errors = JSON::Validator.fully_validate_schema(schema)

        raise ArgumentError, "Invalid input_schema format: #{validation_errors.join("; ")}" unless validation_errors.empty?
      rescue JSON::Schema::ValidationError => e
        raise ArgumentError, "Invalid input_schema format: #{e.message}"
      rescue JSON::Schema::SchemaError => e
        raise ArgumentError, "Invalid input_schema structure: #{e.message}"
      end

      # Validates the structure of the `arguments` array provided to {#register_prompt}.
      # @api private
      def validate_prompt_arguments(argument_defs)
        raise ArgumentError, "Prompt arguments definition must be an Array of Hashes." unless argument_defs.is_a?(Array)

        argument_defs.each_with_index { |arg, idx| validate_single_prompt_argument(arg, idx) }
      end

      # Defines the keys allowed in a prompt argument definition hash.
      ALLOWED_PROMPT_ARG_KEYS = %w[name description required type].freeze
      private_constant :ALLOWED_PROMPT_ARG_KEYS

      # Validates a single prompt argument definition hash.
      # @api private
      def validate_single_prompt_argument(arg, idx)
        raise ArgumentError, "Prompt argument definition at index #{idx} must be a Hash. Found: #{arg.class}" unless arg.is_a?(Hash)

        validate_prompt_arg_name!(arg, idx)
        validate_prompt_arg_description!(arg, idx)
        validate_prompt_arg_required_flag!(arg, idx)
        validate_prompt_arg_type!(arg, idx)
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
        return unless arg.key?(:description) || arg.key?("description")

        desc_val = arg[:description] || arg["description"]
        return if desc_val.nil? || desc_val.is_a?(String)

        raise ArgumentError, "Prompt argument :description at index #{idx} must be a String if provided. Found: #{desc_val.class}"
      end

      # Validates the :required key of a prompt argument definition.
      # @api private
      def validate_prompt_arg_required_flag!(arg, idx)
        return unless arg.key?(:required) || arg.key?("required")

        req_val = arg[:required] || arg["required"]
        return if [true, false].include?(req_val)

        raise ArgumentError, "Prompt argument :required at index #{idx} must be true or false if provided. Found: #{req_val.inspect}"
      end

      # Validates the :type key of a prompt argument definition.
      # @api private
      def validate_prompt_arg_type!(arg, idx)
        return unless arg.key?(:type) || arg.key?("type")

        type_val = arg[:type] || arg["type"]
        return if type_val.nil? || type_val.is_a?(String)

        raise ArgumentError, "Prompt argument :type at index #{idx} must be a String if provided (e.g., JSON schema type). Found: #{type_val.class}"
      end

      # Checks for any unknown keys in a prompt argument definition.
      # @api private
      def validate_prompt_arg_unknown_keys!(arg, idx)
        unknown_keys = arg.transform_keys(&:to_s).keys - ALLOWED_PROMPT_ARG_KEYS
        return if unknown_keys.empty?

        raise ArgumentError,
              "Prompt argument definition at index #{idx} contains unknown keys: #{unknown_keys.join(", ")}. " \
              "Allowed: #{ALLOWED_PROMPT_ARG_KEYS.join(", ")}."
      end
    end
  end
end
