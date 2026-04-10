# frozen_string_literal: true

require "date"
require "time"
require_relative "errors"

module VectorMCP
  # Abstract base class for declarative tool definitions.
  #
  # Subclass this to define tools using a class-level DSL instead of
  # the block-based +register_tool+ API. The two styles are fully
  # interchangeable -- both produce the same +VectorMCP::Definitions::Tool+
  # struct that the rest of the system consumes.
  #
  # @example
  #   class ListProviders < VectorMCP::Tool
  #     tool_name   "list_providers"
  #     description "List providers filtered by category or status"
  #
  #     param :category, type: :string, desc: "Filter by category slug"
  #     param :active,   type: :boolean, default: true
  #
  #     def call(args, session)
  #       Provider.where(active: args.fetch("active", true))
  #     end
  #   end
  #
  #   server.register(ListProviders)
  #
  class Tool
    # Maps Ruby symbol types to JSON Schema property fragments.
    # Each value is merged into the generated property hash, so it may carry
    # both +type+ and +format+ (or any other JSON Schema keyword).
    TYPE_MAP = {
      string: { "type" => "string" },
      integer: { "type" => "integer" },
      number: { "type" => "number" },
      boolean: { "type" => "boolean" },
      array: { "type" => "array" },
      object: { "type" => "object" },
      date: { "type" => "string", "format" => "date" },
      datetime: { "type" => "string", "format" => "date-time" }
    }.freeze

    # Maps Ruby symbol types to a coercer lambda. Types not listed here
    # pass their values through unchanged. Coercers receive the raw value
    # (or nil) and return the coerced value. They must be total over the
    # values JSON Schema validation would accept.
    COERCERS = {
      date: ->(v) { v.nil? || v.is_a?(Date) ? v : Date.parse(v.to_s) },
      datetime: ->(v) { v.nil? || v.is_a?(Time) ? v : Time.parse(v.to_s) }
    }.freeze

    # Ensures each subclass gets its own +@params+ array so sibling
    # classes do not share mutable state.
    def self.inherited(subclass)
      super
      subclass.instance_variable_set(:@params, [])
    end

    # Sets or retrieves the tool name.
    #
    # When called with an argument, stores the name.
    # When called without, returns the stored name or derives one from the class name.
    #
    # @param name [String, Symbol, nil] The tool name to set.
    # @return [String] The tool name.
    def self.tool_name(name = nil)
      if name
        @tool_name = name.to_s
      else
        @tool_name || derive_tool_name
      end
    end

    # Sets or retrieves the tool description.
    #
    # @param text [String, nil] The description to set.
    # @return [String, nil] The description.
    def self.description(text = nil)
      if text
        @description = text
      else
        @description
      end
    end

    # Declares a parameter for the tool's input schema.
    #
    # @param name [Symbol, String] The parameter name.
    # @param type [Symbol] The parameter type (:string, :integer, :number, :boolean, :array, :object).
    # @param desc [String, nil] A human-readable description.
    # @param required [Boolean] Whether the parameter is required (default: false).
    # @param options [Hash] Additional JSON Schema keywords (enum:, default:, format:, items:, etc.).
    def self.param(name, type: :string, desc: nil, required: false, **options)
      @params << {
        name: name.to_s,
        type: type,
        desc: desc,
        required: required,
        options: options
      }
    end

    # Builds a +VectorMCP::Definitions::Tool+ struct from the DSL metadata.
    #
    # @return [VectorMCP::Definitions::Tool]
    # @raise [ArgumentError] If the subclass is missing a description or +#call+ method.
    def self.to_definition
      validate_tool_class!

      VectorMCP::Definitions::Tool.new(
        tool_name,
        description,
        build_input_schema,
        build_handler
      )
    end

    # The handler method that subclasses must implement.
    #
    # @param _args [Hash] The tool arguments (string keys).
    # @param _session [VectorMCP::Session] The current session.
    # @return [Object] The tool result.
    def call(_args, _session)
      raise NotImplementedError, "#{self.class.name} must implement #call(args, session)"
    end

    # Derives a snake_case tool name from the class name.
    def self.derive_tool_name
      base = name&.split("::")&.last
      return "unnamed_tool" unless base

      base.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
    end
    private_class_method :derive_tool_name

    # Validates that the subclass is properly configured.
    def self.validate_tool_class!
      raise ArgumentError, "#{name || self} must declare a description" unless description
      return if method_defined?(:call) && instance_method(:call).owner != VectorMCP::Tool

      raise ArgumentError, "#{name || self} must implement #call"
    end
    private_class_method :validate_tool_class!

    # Builds a 2-arity handler lambda. A new instance is created per invocation.
    # Arguments are coerced based on the declared param types before the
    # handler sees them (e.g. :date param strings become Date objects).
    def self.build_handler
      klass = self
      params = @params
      ->(args, session) { klass.new.call(klass.coerce_args(args, params), session) }
    end
    private_class_method :build_handler

    # Applies coercers to the raw argument hash. Returns a new hash; does
    # not mutate the original. Keys without a coercible type pass through.
    # Keys that are absent from +args+ stay absent — coercion only fires
    # for keys actually present.
    #
    # A parse failure on a client-supplied value is translated into
    # +VectorMCP::InvalidParamsError+ (JSON-RPC -32602) so the client sees
    # a "bad request" response instead of a generic internal error.
    # This is needed because the +json-schema+ gem does not enforce
    # +format: date+ upstream (it does enforce +format: date-time+), so
    # malformed +:date+ values would otherwise crash inside +Date.parse+.
    def self.coerce_args(args, params)
      coerced = args.dup
      params.each do |param|
        name = param[:name]
        next unless coerced.key?(name)

        coercer = COERCERS[param[:type]]
        next unless coercer

        begin
          coerced[name] = coercer.call(coerced[name])
        rescue ArgumentError, TypeError => e
          # Date::Error < ArgumentError in Ruby 3.2+, so ArgumentError alone covers Date.parse failures.
          raise VectorMCP::InvalidParamsError.new(
            "Invalid #{param[:type]} value for param '#{name}': #{e.message}",
            details: { param: name, type: param[:type], message: e.message }
          )
        end
      end
      coerced
    end

    # Builds a JSON Schema hash from the declared params.
    def self.build_input_schema
      properties = {}
      required = []

      @params.each do |param|
        type_fragment = TYPE_MAP.fetch(param[:type]) do
          raise ArgumentError, "Unknown param type :#{param[:type]} for param '#{param[:name]}' in #{name}. " \
                               "Valid types: #{TYPE_MAP.keys.join(", ")}"
        end

        prop = type_fragment.dup
        prop["description"] = param[:desc] if param[:desc]

        param[:options].each do |key, value|
          prop[key.to_s] = value
        end

        properties[param[:name]] = prop
        required << param[:name] if param[:required]
      end

      schema = {
        "type" => "object",
        "properties" => properties
      }
      schema["required"] = required unless required.empty?
      schema
    end
    private_class_method :build_input_schema
  end
end
