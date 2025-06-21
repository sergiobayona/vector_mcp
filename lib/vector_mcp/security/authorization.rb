# frozen_string_literal: true

module VectorMCP
  module Security
    # Manages authorization policies for VectorMCP servers
    # Provides fine-grained access control for tools and resources
    class Authorization
      attr_reader :policies, :enabled

      def initialize
        @policies = {}
        @enabled = false
      end

      # Enable authorization system
      def enable!
        @enabled = true
      end

      # Disable authorization (return to pass-through mode)
      def disable!
        @enabled = false
      end

      # Add an authorization policy for a resource type
      # @param resource_type [Symbol] the type of resource (e.g., :tool, :resource, :prompt)
      # @param block [Proc] the policy block that receives (user, action, resource)
      def add_policy(resource_type, &block)
        @policies[resource_type] = block
      end

      # Remove an authorization policy
      # @param resource_type [Symbol] the resource type to remove policy for
      def remove_policy(resource_type)
        @policies.delete(resource_type)
      end

      # Check if a user is authorized to perform an action on a resource
      # @param user [Object] the authenticated user object
      # @param action [Symbol] the action being attempted (e.g., :call, :read, :list)
      # @param resource [Object] the resource being accessed
      # @return [Boolean] true if authorized, false otherwise
      def authorize(user, action, resource)
        return true unless @enabled

        resource_type = determine_resource_type(resource)
        policy = @policies[resource_type]

        # If no policy is defined, allow access (opt-in authorization)
        return true unless policy

        begin
          policy_result = policy.call(user, action, resource)
          policy_result ? true : false
        rescue StandardError
          # Log error but deny access for safety
          false
        end
      end

      # Check if authorization is required
      # @return [Boolean] true if authorization is enabled
      def required?
        @enabled
      end

      # Get list of resource types with policies
      # @return [Array<Symbol>] array of resource types
      def policy_types
        @policies.keys
      end

      private

      # Determine the resource type from the resource object
      # @param resource [Object] the resource object
      # @return [Symbol] the resource type
      def determine_resource_type(resource)
        case resource
        when VectorMCP::Definitions::Tool
          :tool
        when VectorMCP::Definitions::Resource
          :resource
        when VectorMCP::Definitions::Prompt
          :prompt
        when VectorMCP::Definitions::Root
          :root
        else
          # Try to infer from class name
          class_name = resource.class.name.split("::").last&.downcase
          class_name&.to_sym || :unknown
        end
      end
    end
  end
end
