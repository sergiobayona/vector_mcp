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

      # Registers one or more class-based tool definitions with the server.
      #
      # Each argument must be a subclass of +VectorMCP::Tool+ that declares
      # its metadata via the class-level DSL (+tool_name+, +description+,
      # +param+) and implements +#call+.
      #
      # @param tool_classes [Array<Class>] One or more +VectorMCP::Tool+ subclasses.
      # @return [self] The server instance, for chaining.
      # @raise [ArgumentError] If any argument is not a +VectorMCP::Tool+ subclass.
      #
      # @example Register a single tool
      #   server.register(ListProviders)
      #
      # @example Register multiple tools
      #   server.register(ListProviders, CreateProvider, UpdateProvider)
      def register(*tool_classes)
        tool_classes.each do |tool_class|
          unless tool_class.is_a?(Class) && tool_class < VectorMCP::Tool
            raise ArgumentError, "#{tool_class.inspect} is not a VectorMCP::Tool subclass"
          end

          definition = tool_class.to_definition
          register_tool(
            name: definition.name,
            description: definition.description,
            input_schema: definition.input_schema,
            &definition.handler
          )
        end
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
      # Thin wrapper: delegates schema-building to Definitions::Resource.from_image_file,
      # then stores the result via register_resource.
      #
      # @param uri [String] Unique URI for the resource.
      # @param file_path [String] Path to the image file.
      # @param name [String, nil] Human-readable name (auto-generated if nil).
      # @param description [String, nil] Description (auto-generated if nil).
      # @return [self]
      # @raise [ArgumentError] If the file doesn't exist or isn't a valid image.
      def register_image_resource(uri:, file_path:, name: nil, description: nil)
        resource = VectorMCP::Definitions::Resource.from_image_file(
          uri: uri, file_path: file_path, name: name, description: description
        )
        register_resource(uri: resource.uri, name: resource.name,
                          description: resource.description, mime_type: resource.mime_type, &resource.handler)
      end

      # Helper method to register an image resource from binary data.
      # Thin wrapper: delegates to Definitions::Resource.from_image_data.
      #
      # @param uri [String] Unique URI for the resource.
      # @param image_data [String] Binary image data.
      # @param name [String] Human-readable name.
      # @param description [String, nil] Description (auto-generated if nil).
      # @param mime_type [String, nil] MIME type (auto-detected if nil).
      # @return [self]
      def register_image_resource_from_data(uri:, image_data:, name:, description: nil, mime_type: nil)
        resource = VectorMCP::Definitions::Resource.from_image_data(
          uri: uri, image_data: image_data, name: name, description: description, mime_type: mime_type
        )
        register_resource(uri: resource.uri, name: resource.name,
                          description: resource.description, mime_type: resource.mime_type, &resource.handler)
      end

      # Helper method to register a tool that accepts image inputs.
      # Thin wrapper: delegates schema-building to Definitions::Tool.with_image_support.
      #
      # @param name [String] Unique name for the tool.
      # @param description [String] Human-readable description.
      # @param image_parameter [String] Name of the image parameter (default: "image").
      # @param additional_parameters [Hash] Additional JSON Schema properties.
      # @param required_parameters [Array<String>] List of required parameter names.
      # @return [self]
      def register_image_tool(name:, description:, image_parameter: "image",
                              additional_parameters: {}, required_parameters: [], &handler)
        tool = VectorMCP::Definitions::Tool.with_image_support(
          name: name, description: description, image_parameter: image_parameter,
          additional_parameters: additional_parameters, required_parameters: required_parameters, &handler
        )
        register_tool(name: tool.name, description: tool.description,
                      input_schema: tool.input_schema, &tool.handler)
      end

      # Helper method to register a prompt that supports image arguments.
      # Thin wrapper: delegates to Definitions::Prompt.with_image_support.
      #
      # @param name [String] Unique name for the prompt.
      # @param description [String] Human-readable description.
      # @param image_argument [String] Name of the image argument (default: "image").
      # @param additional_arguments [Array<Hash>] Additional prompt arguments.
      # @return [self]
      def register_image_prompt(name:, description:, image_argument: "image", additional_arguments: [], &handler)
        prompt = VectorMCP::Definitions::Prompt.with_image_support(
          name: name, description: description, image_argument_name: image_argument,
          additional_arguments: additional_arguments, &handler
        )
        register_prompt(name: prompt.name, description: prompt.description,
                        arguments: prompt.arguments, &prompt.handler)
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

      # Schema for a single prompt argument definition. Each entry names the
      # required/optional key, whether it is required, and the rule that validates
      # its value. Rules return nil on success or an error message fragment.
      PROMPT_ARG_SCHEMA = {
        "name" => {
          required: true,
          missing_message: "missing :name",
          rule: lambda { |v|
            next "must be a String or Symbol. Found: #{v.class}" unless v.is_a?(String) || v.is_a?(Symbol)

            "cannot be empty." if v.to_s.strip.empty?
          }
        },
        "description" => {
          required: false,
          rule: ->(v) { "must be a String if provided. Found: #{v.class}" unless v.nil? || v.is_a?(String) }
        },
        "required" => {
          required: false,
          rule: ->(v) { "must be true or false if provided. Found: #{v.inspect}" unless [true, false].include?(v) }
        },
        "type" => {
          required: false,
          rule: ->(v) { "must be a String if provided (e.g., JSON schema type). Found: #{v.class}" unless v.nil? || v.is_a?(String) }
        }
      }.freeze
      private_constant :PROMPT_ARG_SCHEMA

      # Validates the structure of the `arguments` array provided to {#register_prompt}.
      # @api private
      def validate_prompt_arguments(argument_defs)
        raise ArgumentError, "Prompt arguments definition must be an Array of Hashes." unless argument_defs.is_a?(Array)

        argument_defs.each_with_index { |arg, idx| validate_single_prompt_argument(arg, idx) }
      end

      # Validates a single prompt argument definition hash against PROMPT_ARG_SCHEMA.
      # @api private
      def validate_single_prompt_argument(arg, idx)
        raise ArgumentError, "Prompt argument definition at index #{idx} must be a Hash. Found: #{arg.class}" unless arg.is_a?(Hash)

        PROMPT_ARG_SCHEMA.each { |key, spec| validate_prompt_arg_field(arg, idx, key, spec) }
        validate_prompt_arg_unknown_keys(arg, idx)
      end

      # Validates a single field of a prompt argument hash against its schema spec.
      # @api private
      def validate_prompt_arg_field(arg, idx, key, spec)
        present = arg.key?(key.to_sym) || arg.key?(key)
        value = arg[key.to_sym] || arg[key]

        raise ArgumentError, "Prompt argument at index #{idx} #{spec[:missing_message]}" if spec[:required] && value.nil?
        return unless present

        error_fragment = spec[:rule].call(value)
        raise ArgumentError, "Prompt argument :#{key} at index #{idx} #{error_fragment}" if error_fragment
      end

      # Checks a prompt argument hash for keys outside PROMPT_ARG_SCHEMA.
      # @api private
      def validate_prompt_arg_unknown_keys(arg, idx)
        unknown_keys = arg.transform_keys(&:to_s).keys - PROMPT_ARG_SCHEMA.keys
        return if unknown_keys.empty?

        raise ArgumentError,
              "Prompt argument definition at index #{idx} contains unknown keys: #{unknown_keys.join(", ")}. " \
              "Allowed: #{PROMPT_ARG_SCHEMA.keys.join(", ")}."
      end
    end
  end
end
