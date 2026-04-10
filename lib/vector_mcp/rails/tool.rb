# frozen_string_literal: true

require "active_record"
require "active_support/core_ext/hash/indifferent_access"
require "vector_mcp/tool"

module VectorMCP
  module Rails
    # Rails-aware base class for declarative tool definitions.
    #
    # Adds ergonomics for the common patterns that show up in ActiveRecord-
    # backed MCP tools:
    #
    # * +find!+ -- fetch a record or raise +VectorMCP::NotFoundError+
    # * +respond_with+ -- standard success/error payload from a record
    # * +with_transaction+ -- wrap a mutation in an AR transaction
    # * Auto-rescue of +ActiveRecord::RecordNotFound+ (-> NotFoundError)
    #   and +ActiveRecord::RecordInvalid+ (-> error payload)
    # * Arguments delivered to +#call+ as a +HashWithIndifferentAccess+
    #   so +args[:id]+ and +args["id"]+ both work
    #
    # @example
    #   class UpdateProvider < VectorMCP::Rails::Tool
    #     tool_name   "update_provider"
    #     description "Update an existing provider"
    #
    #     param :id,   type: :integer, required: true
    #     param :name, type: :string
    #
    #     def call(args, _session)
    #       provider = find!(Provider, args[:id])
    #       provider.update(args.except(:id))
    #       respond_with(provider, name: provider.name)
    #     end
    #   end
    class Tool < VectorMCP::Tool
      # Overrides the parent handler to add indifferent-access args and
      # auto-rescue ActiveRecord exceptions.
      def self.build_handler
        klass = self
        params = @params
        lambda do |args, session|
          coerced = klass.coerce_args(args, params).with_indifferent_access
          klass.new.call(coerced, session)
        rescue ActiveRecord::RecordNotFound => e
          raise VectorMCP::NotFoundError, e.message
        rescue ActiveRecord::RecordInvalid => e
          { success: false, errors: e.record.errors.full_messages }
        end
      end
      private_class_method :build_handler

      # Finds a record by id or raises VectorMCP::NotFoundError.
      #
      # @param model [Class] an ActiveRecord model class
      # @param id [Integer, String] the record id
      # @return [ActiveRecord::Base]
      def find!(model, id)
        model.find_by(id: id) ||
          raise(VectorMCP::NotFoundError, "#{model.name} #{id} not found")
      end

      # Builds a standard response payload from a record.
      #
      # Success shape: +{ success: true, id: record.id, **extras }+
      # Error shape:   +{ success: false, errors: record.errors.full_messages }+
      #
      # @param record [ActiveRecord::Base]
      # @param extras [Hash] additional keys to merge into the success payload
      # @return [Hash]
      def respond_with(record, **extras)
        if record.persisted? && record.errors.empty?
          { success: true, id: record.id, **extras }
        else
          { success: false, errors: record.errors.full_messages }
        end
      end

      # Runs the given block inside an ActiveRecord transaction.
      def with_transaction(&)
        ActiveRecord::Base.transaction(&)
      end
    end
  end
end
