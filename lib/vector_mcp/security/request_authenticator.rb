# frozen_string_literal: true

require_relative "../middleware"
require_relative "../request_context"

module VectorMCP
  module Security
    # Authenticates one request-scoped invocation and runs the auth middleware hooks.
    # The resolved identity is cached only on Invocation, never on the shared Session.
    class RequestAuthenticator
      OPERATION_TYPES = {
        "tools/list" => :tool_list,
        "tools/call" => :tool_call,
        "resources/list" => :resource_list,
        "resources/read" => :resource_read,
        "prompts/list" => :prompt_list,
        "prompts/get" => :prompt_get,
        "roots/list" => :root_list
      }.freeze

      OPERATION_NAME_PARAMS = {
        "tools/call" => "name",
        "resources/read" => "uri",
        "prompts/get" => "name"
      }.freeze

      class << self
        # Authenticate a protocol message using operation metadata derived from its method.
        def authenticate_message!(method, params, session, server)
          operation_type = OPERATION_TYPES.fetch(method, :request)
          name_param = OPERATION_NAME_PARAMS[method]
          operation_name = name_param ? params[name_param] || params[name_param.to_sym] : method

          authenticate!(session, server, operation_type: operation_type, operation_name: operation_name)
        end

        # Authenticate the current request and return its resolved identity.
        def authenticate!(session, server, operation_type:, operation_name:)
          return session.security_context if authentication_resolved?(session)

          context = nil
          request = request_context_for(session)
          context = auth_context(operation_type, operation_name, request.to_h, session, server)
          context = server.middleware_manager.execute_hooks(:before_auth, context)
          raise context.error if context.error?

          session_context = server.security_middleware.authenticate_request(context.params)
          session.security_context = session_context

          raise VectorMCP::UnauthorizedError, "Authentication required" if server.auth_manager.required? && !session_context.authenticated?

          context.result = session_context
          server.middleware_manager.execute_hooks(:after_auth, context)
          session_context
        rescue StandardError => e
          handle_auth_error(e, context, server)
        end

        # Extract the immutable request context carried by the invocation/session.
        def request_context_for(session)
          unless session.respond_to?(:request_context) && session.request_context
            raise VectorMCP::InternalError,
                  "Session missing request_context - transport layer integration error. Session ID: #{session.id}"
          end

          session.request_context
        end

        private

        def authentication_resolved?(session)
          session.respond_to?(:authentication_resolved?) && session.authentication_resolved?
        end

        def auth_context(operation_type, operation_name, request, session, server)
          VectorMCP::Middleware::Context.new(
            operation_type: operation_type,
            operation_name: operation_name,
            params: request,
            session: session,
            server: server,
            metadata: { start_time: Time.now }
          )
        end

        def handle_auth_error(error, context, server)
          if context
            context.error = error
            server.middleware_manager.execute_hooks(:on_auth_error, context)
          end

          raise error
        end
      end
    end
  end
end
