# frozen_string_literal: true

require "spec_helper"

RSpec.describe VectorMCP::Security::AuthenticationRateLimiter do
  let(:current_time) { [100.0] }
  let(:clock) { -> { current_time.first } }
  let(:limiter) { described_class.new(max_attempts: 2, window_seconds: 60, max_entries: 10, clock: clock) }

  def request(ip: "192.0.2.1", credential: "invalid-key")
    VectorMCP::RequestContext.new(
      headers: credential ? { "X-API-Key" => credential } : {},
      transport_metadata: { remote_addr: ip }
    )
  end

  def fail_auth(limiter, context)
    limiter.check!(context)
    limiter.record_failure(context)
  end

  it "blocks an identifier after the configured number of failures" do
    context = request

    2.times { fail_auth(limiter, context) }

    expect { limiter.check!(context) }
      .to raise_error(VectorMCP::RateLimitExceededError) do |error|
        expect(error.retry_after).to eq(60)
        expect(error.code).to eq(-32_029)
      end
  end

  it "limits attempts sharing an IP even when credentials rotate" do
    fail_auth(limiter, request(credential: "guess-one"))
    fail_auth(limiter, request(credential: "guess-two"))

    expect { limiter.check!(request(credential: "guess-three")) }
      .to raise_error(VectorMCP::RateLimitExceededError)
  end

  it "limits attempts sharing a credential across different IP addresses" do
    fail_auth(limiter, request(ip: "192.0.2.1"))
    fail_auth(limiter, request(ip: "192.0.2.2"))

    expect { limiter.check!(request(ip: "192.0.2.3")) }
      .to raise_error(VectorMCP::RateLimitExceededError)
  end

  it "resets matching counters after successful authentication" do
    context = request
    fail_auth(limiter, context)
    limiter.check!(context)
    limiter.record_success(context)
    fail_auth(limiter, context)

    expect { limiter.check!(context) }.not_to raise_error
  end

  it "allows attempts after the rolling window expires" do
    context = request
    2.times { fail_auth(limiter, context) }
    current_time[0] += 61

    expect { limiter.check!(context) }.not_to raise_error
  end

  it "bounds identifier storage and does not retain raw credentials" do
    limiter = described_class.new(max_attempts: 2, window_seconds: 60, max_entries: 2, clock: clock)
    %w[first-secret second-secret third-secret].each_with_index do |credential, index|
      fail_auth(limiter, request(ip: "192.0.2.#{index + 1}", credential: credential))
    end

    stored_identifiers = limiter.instance_variable_get(:@attempts).keys
    expect(limiter.status[:tracked_entries]).to eq(2)
    expect(stored_identifiers.join).not_to include("secret")
  end

  it "uses a shared fallback bucket when transport identity is unavailable" do
    context = VectorMCP::RequestContext.new
    2.times { fail_auth(limiter, context) }

    expect { limiter.check!(context) }.to raise_error(VectorMCP::RateLimitExceededError)
  end

  it "rejects invalid configuration" do
    expect { described_class.new(max_attempts: 0) }.to raise_error(ArgumentError, /max_attempts/)
    expect { described_class.new(window_seconds: 0) }.to raise_error(ArgumentError, /window_seconds/)
    expect { described_class.new(max_entries: 0) }.to raise_error(ArgumentError, /max_entries/)
  end

  it "reserves attempt slots atomically under concurrency" do
    context = request
    outcomes = Queue.new

    threads = 10.times.map do
      Thread.new do
        limiter.check!(context)
        outcomes << :allowed
      rescue VectorMCP::RateLimitExceededError
        outcomes << :blocked
      end
    end
    threads.each(&:join)

    results = 10.times.map { outcomes.pop }
    expect(results.count(:allowed)).to eq(2)
    expect(results.count(:blocked)).to eq(8)
  end

  it "emits structured threshold events without credentials" do
    security_logger = instance_spy(VectorMCP::Logger)
    allow(VectorMCP).to receive(:logger_for).and_call_original
    allow(VectorMCP).to receive(:logger_for).with("security.auth_rate_limit").and_return(security_logger)
    limiter = described_class.new(max_attempts: 2, window_seconds: 60, clock: clock)
    context = request(credential: "do-not-log-this-key")

    2.times { fail_auth(limiter, context) }

    expect(security_logger).to have_received(:security) do |message, metadata = {}, **keywords|
      metadata = metadata.merge(keywords)
      expect(message).to include("Repeated authentication failures")
      expect(metadata[:event]).to eq("authentication_failure_limit_reached")
      expect(metadata.to_s).not_to include("do-not-log-this-key")
    end
  end
end
