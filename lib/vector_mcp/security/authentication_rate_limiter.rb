# frozen_string_literal: true

require "digest"
require_relative "../errors"
require_relative "../request_context"

module VectorMCP
  module Security
    # In-process limiter for repeated authentication failures.
    #
    # Attempts are tracked independently by transport-provided remote address
    # and by a SHA-256 fingerprint of the presented credential. Raw credentials
    # are never retained. Storage is bounded to avoid turning the limiter into a
    # memory-exhaustion primitive.
    class AuthenticationRateLimiter
      DEFAULT_MAX_ATTEMPTS = 10
      DEFAULT_WINDOW_SECONDS = 60
      DEFAULT_MAX_ENTRIES = 10_000

      CREDENTIAL_HEADERS = %w[Authorization X-API-Key X-JWT-Token].freeze
      CREDENTIAL_PARAMS = %w[api_key apikey jwt_token token].freeze

      attr_reader :max_attempts, :window_seconds, :max_entries

      # @param max_attempts [Integer] failures allowed per identifier and window
      # @param window_seconds [Numeric] rolling failure window in seconds
      # @param max_entries [Integer] maximum number of tracked identifiers
      # @param clock [#call, nil] monotonic time source (primarily for testing)
      def initialize(max_attempts: DEFAULT_MAX_ATTEMPTS,
                     window_seconds: DEFAULT_WINDOW_SECONDS,
                     max_entries: DEFAULT_MAX_ENTRIES,
                     clock: nil)
        validate_positive_integer!(:max_attempts, max_attempts)
        validate_positive_number!(:window_seconds, window_seconds)
        validate_positive_integer!(:max_entries, max_entries)

        @max_attempts = max_attempts
        @window_seconds = window_seconds
        @max_entries = max_entries
        @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        @attempts = {}
        @mutex = Mutex.new
        @logger = VectorMCP.logger_for("security.auth_rate_limit")
      end

      # Atomically reserve an attempt, raising when any request identifier is blocked.
      # @param request [VectorMCP::RequestContext, Hash] incoming request context
      # @return [void]
      # @raise [VectorMCP::RateLimitExceededError]
      def check!(request)
        context = VectorMCP::RequestContext.coerce(request)
        current_time = now
        identifiers = request_identifiers(context)
        retry_after = @mutex.synchronize do
          blocked_for = identifiers.filter_map do |identifier|
            timestamps = active_timestamps(identifier, current_time)
            next unless timestamps.length >= @max_attempts

            timestamps.first + @window_seconds - current_time
          end.max
          unless blocked_for
            identifiers.each do |identifier|
              timestamps = active_timestamps(identifier, current_time)
              timestamps << current_time
              store(identifier, timestamps)
            end
          end
          blocked_for
        end
        return unless retry_after

        seconds = [retry_after.ceil, 1].max
        log_rate_limit(context, seconds)
        raise VectorMCP::RateLimitExceededError.new(retry_after: seconds)
      end

      # Record an unsuccessful authentication result for the reserved attempt.
      # @param request [VectorMCP::RequestContext, Hash] incoming request context
      # @return [void]
      def record_failure(request)
        context = VectorMCP::RequestContext.coerce(request)
        current_time = now
        threshold_reached = @mutex.synchronize do
          request_identifiers(context).filter_map do |identifier|
            timestamps = active_timestamps(identifier, current_time)
            identifier_scope(identifier) if timestamps.length == @max_attempts
          end
        end

        log_failure_threshold(context, threshold_reached) unless threshold_reached.empty?
      end

      # Clear failure history after successful authentication.
      # @param request [VectorMCP::RequestContext, Hash] incoming request context
      # @return [void]
      def record_success(request)
        identifiers = request_identifiers(VectorMCP::RequestContext.coerce(request))
        @mutex.synchronize { identifiers.each { |identifier| @attempts.delete(identifier) } }
      end

      # @return [Hash] non-sensitive limiter status
      def status
        tracked_entries = @mutex.synchronize { @attempts.length }
        {
          enabled: true,
          max_attempts: @max_attempts,
          window_seconds: @window_seconds,
          max_entries: @max_entries,
          tracked_entries: tracked_entries
        }
      end

      private

      def now
        @clock.call
      end

      def request_identifiers(context)
        identifiers = []
        remote_addr = context.metadata("remote_addr").to_s.strip
        identifiers << "ip:#{remote_addr}" unless remote_addr.empty?

        credential = extract_credential(context)
        identifiers << "credential:#{Digest::SHA256.hexdigest(credential)}" if credential

        identifiers.empty? ? ["source:unknown"] : identifiers
      end

      def extract_credential(context)
        credential_values = context.headers.filter_map do |name, item|
          item if CREDENTIAL_HEADERS.any? { |credential_header| credential_header.casecmp?(name) }
        end
        value = credential_values.find { |item| !item.strip.empty? }
        value ||= CREDENTIAL_PARAMS.filter_map { |name| context.param(name) }.find { |item| !item.strip.empty? }
        value&.strip
      end

      def active_timestamps(identifier, current_time)
        cutoff = current_time - @window_seconds
        (@attempts[identifier] || []).drop_while { |timestamp| timestamp <= cutoff }
      end

      def store(identifier, timestamps)
        @attempts.delete(identifier)
        @attempts.shift while @attempts.length >= @max_entries
        @attempts[identifier] = timestamps.last(@max_attempts)
      end

      def identifier_scope(identifier)
        identifier.split(":", 2).first
      end

      def log_failure_threshold(context, scopes)
        @logger.security(
          "Repeated authentication failures reached configured limit",
          event: "authentication_failure_limit_reached",
          remote_addr: context.metadata("remote_addr"),
          scopes: scopes.uniq.join(","),
          max_attempts: @max_attempts,
          window_seconds: @window_seconds
        )
      end

      def log_rate_limit(context, retry_after)
        @logger.security(
          "Authentication attempt rate limited",
          event: "authentication_rate_limited",
          remote_addr: context.metadata("remote_addr"),
          retry_after: retry_after
        )
      end

      def validate_positive_integer!(name, value)
        return if value.is_a?(Integer) && value.positive?

        raise ArgumentError, "#{name} must be a positive Integer"
      end

      def validate_positive_number!(name, value)
        return if value.is_a?(Numeric) && value.positive?

        raise ArgumentError, "#{name} must be a positive number"
      end
    end
  end
end
