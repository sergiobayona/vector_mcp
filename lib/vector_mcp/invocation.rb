# frozen_string_literal: true

require "forwardable"
require_relative "request_context"
require_relative "security/session_context"

module VectorMCP
  # A per-request view of a {Session}.
  #
  # Carries the request-scoped state — the incoming request's
  # {RequestContext} and the {Security::SessionContext} resolved for it —
  # while delegating session-lived state (identity, initialization,
  # user data, sampling) to the underlying session. Transports build one
  # Invocation per incoming request and pass it through message dispatch,
  # so concurrent requests on the same session each observe their own
  # request data and authentication result.
  #
  # The Invocation intentionally quacks like a {Session}: tool handlers and
  # request/notification hooks receive it as their `session` argument and
  # can keep using `session.id`, `session.data`, `session.sample`,
  # `session.request_header`, and `session.security_context` unchanged.
  class Invocation
    extend Forwardable

    # @return [VectorMCP::Session] the underlying session this request belongs to
    attr_reader :session

    # @return [VectorMCP::RequestContext] this request's context (headers, params, ...)
    attr_reader :request_context

    # @return [VectorMCP::Security::SessionContext] the security context resolved for this request
    attr_reader :security_context

    def_delegators :@session,
                   :id, :server, :transport, :data,
                   :initialized?, :initialize!, :sample,
                   :server_info, :server_capabilities, :protocol_version,
                   :client_info, :client_capabilities

    # The resolved auth API is exposed directly so handlers written against
    # Security::SessionContext (the legacy second argument of resource
    # handlers) keep working when they receive the invocation instead.
    def_delegators :@security_context,
                   :user, :authenticated, :authenticated?, :auth_strategy, :authenticated_at,
                   :permissions, :can?, :can_access?, :add_permission, :add_permissions,
                   :remove_permission, :clear_permissions, :user_identifier, :auth_method,
                   :auth_recent?

    # @param session [VectorMCP::Session] the session the request arrived on
    # @param request_context [RequestContext, Hash, nil] this request's context;
    #   defaults to the session's stored context when not provided
    def initialize(session, request_context: nil)
      @session = session
      @request_context = request_context ? RequestContext.coerce(request_context) : session.request_context
      @security_context = Security::SessionContext.anonymous
      @authentication_resolved = false
    end

    # Store the identity resolved for this invocation. Assigning a context marks
    # authentication as complete even when the resolved identity is anonymous.
    def security_context=(context)
      @security_context = context
      @authentication_resolved = true
    end

    # @return [Boolean] whether authentication has run for this invocation
    def authentication_resolved?
      @authentication_resolved
    end

    # Replace this request's context (e.g. from middleware).
    # @param context [RequestContext, Hash] the new request context
    def request_context=(context)
      @request_context = RequestContext.coerce(context)
    end

    # Merge attributes into this request's context.
    # @param attributes [Hash] attributes to merge
    # @return [RequestContext] the updated request context
    def update_request_context(**attributes)
      @request_context = @request_context.merge(attributes)
    end

    # @return [Boolean] whether this request carried any headers
    def request_headers?
      @request_context.headers?
    end

    # @return [Boolean] whether this request carried any query parameters
    def request_params?
      @request_context.params?
    end

    # @param name [String] the header name
    # @return [String, nil] the header value for this request
    def request_header(name)
      @request_context.header(name)
    end

    # @param name [String] the parameter name
    # @return [String, nil] the parameter value for this request
    def request_param(name)
      @request_context.param(name)
    end

    # Invocations compare by their underlying session so request-scoped views
    # retain the identity semantics of that shared session.
    def ==(other)
      other_session = other.is_a?(Invocation) ? other.session : other
      @session == other_session
    end
    alias eql? ==

    def hash
      @session.hash
    end
  end
end
