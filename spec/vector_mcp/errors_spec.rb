# frozen_string_literal: true

require "spec_helper"

RSpec.describe "VectorMCP Errors" do
  # Helper to create error instance with defaults for cleaner tests
  def create_error(error_class, *args, **kwargs)
    # Add default request_id unless specified
    kwargs[:request_id] ||= "test_req_id"
    # Ensure details is passed if needed
    kwargs[:details] = {} if kwargs[:details].nil? && error_class.instance_method(:initialize).parameters.any? { |p| p[1] == :details }
    error_class.new(*args, **kwargs)
  rescue ArgumentError => e
    # Provide more context if initialization fails
    raise ArgumentError, "Failed to initialize #{error_class} with args: #{args.inspect}, kwargs: #{kwargs.inspect}. Error: #{e.message}", e.backtrace
  end

  describe VectorMCP::Error do
    it "is a subclass of StandardError" do
      expect(described_class).to be < StandardError
    end
  end

  describe VectorMCP::ProtocolError do
    let(:message) { "Protocol failure" }
    let(:code) { -32_123 }
    let(:details) { { info: "extra" } }
    let(:request_id) { "req-1" }

    it "is a subclass of VectorMCP::Error" do
      expect(described_class).to be < VectorMCP::Error
    end

    it "has the correct attributes" do
      error = described_class.new(message, code: code, details: details, request_id: request_id)
      expect(error.message).to eq(message)
      expect(error.code).to eq(code)
      expect(error.details).to eq(details)
      expect(error.request_id).to eq(request_id)
    end

    context "when optional parameters are not provided" do
      let(:error) { described_class.new(message) }

      it "sets request_id to nil" do
        # Explicitly create without request_id
        error_no_req = described_class.new(message)
        expect(error_no_req.request_id).to be_nil
      end

      it "sets details to nil" do
        # Explicitly create without details
        error_no_details = described_class.new(message)
        expect(error_no_details.details).to be_nil
      end
    end
  end

  describe VectorMCP::ParseError do
    let(:request_id) { "123" }
    let(:details) { { line: 42 } }

    it "is a subclass of ProtocolError" do
      expect(described_class).to be < VectorMCP::ProtocolError
    end

    it "has the correct default message" do
      error = described_class.new
      expect(error.message).to eq("Parse error")
    end

    it "has the correct error code" do
      error = described_class.new
      expect(error.code).to eq(-32_700)
    end

    it "accepts custom message and parameters" do
      error = described_class.new("Custom message", request_id: request_id, details: details)
      expect(error.message).to eq("Custom message")
      expect(error.request_id).to eq(request_id)
      expect(error.details).to eq(details)
    end
  end

  describe VectorMCP::InvalidRequestError do
    it "is a subclass of ProtocolError" do
      expect(described_class).to be < VectorMCP::ProtocolError
    end

    it "has the correct default message" do
      error = described_class.new
      expect(error.message).to eq("Invalid Request")
    end

    it "has the correct error code" do
      error = described_class.new
      expect(error.code).to eq(-32_600)
    end
  end

  describe VectorMCP::MethodNotFoundError do
    let(:method_name) { "nonexistent_method" }
    let(:error) { described_class.new(method_name) }

    it "is a subclass of ProtocolError" do
      expect(described_class).to be < VectorMCP::ProtocolError
    end

    it "has the correct default message" do
      # Message should include the method name
      expect(error.message).to eq("Method not found: #{method_name}")
    end

    it "has the correct error code" do
      expect(error.code).to eq(-32_601)
    end

    it "includes the method name in details" do
      expect(error.details).to eq({ method_name: method_name })
    end

    context "when custom details provided" do
      it "uses the provided details when they don't include method_name" do
        custom_details = { foo: "bar" }
        error = described_class.new(method_name, details: custom_details)
        expect(error.details).to eq(custom_details)
      end

      it "keeps provided method_name when custom details include method_name" do
        custom_details = { method_name: "different_method", foo: "bar" }
        error = described_class.new(method_name, details: custom_details)
        expect(error.details).to eq(custom_details)
      end
    end
  end

  describe VectorMCP::InvalidParamsError do
    it "is a subclass of ProtocolError" do
      expect(described_class).to be < VectorMCP::ProtocolError
    end

    it "has the correct default message" do
      error = described_class.new
      expect(error.message).to eq("Invalid params")
    end

    it "has the correct error code" do
      error = described_class.new
      expect(error.code).to eq(-32_602)
    end
  end

  describe VectorMCP::InternalError do
    let(:error) { described_class.new }

    it "is a subclass of ProtocolError" do
      expect(described_class).to be < VectorMCP::ProtocolError
    end

    it "has the correct default message" do
      expect(error.message).to eq("Internal error")
    end

    it "has the correct error code" do
      expect(error.code).to eq(-32_603)
    end
  end

  describe VectorMCP::ServerError do
    let(:message) { "Custom server error" }
    let(:code) { -32_000 }
    let(:request_id) { "123" }
    let(:details) { { error: "details" } }

    it "is a subclass of ProtocolError" do
      expect(described_class).to be < VectorMCP::ProtocolError
    end

    it "has the correct default message" do
      error = described_class.new
      expect(error.message).to eq("Server error")
    end

    it "has the correct default error code" do
      error = described_class.new
      expect(error.code).to eq(-32_000)
    end

    it "accepts custom parameters" do
      error = described_class.new(message, code: code, request_id: request_id, details: details)
      expect(error.message).to eq(message)
      expect(error.code).to eq(code)
      expect(error.request_id).to eq(request_id)
      expect(error.details).to eq(details)
    end

    context "when provided code outside the reserved range" do
      it "emits a warning and defaults code to -32000 for code above range" do
        code = -31_000
        error = nil
        expect do
          error = described_class.new("Bad server error", code: code)
        end.to output(/Server error code #{code} is outside of the reserved range/).to_stderr
        expect(error.code).to eq(-32_000)
      end

      it "emits a warning and defaults code to -32000 for code below range" do
        code = -32_100
        error = nil
        expect do
          error = described_class.new("Bad server error", code: code)
        end.to output(/Server error code #{code} is outside of the reserved range/).to_stderr
        expect(error.code).to eq(-32_000)
      end
    end
  end

  describe VectorMCP::InitializationError do
    it "is a subclass of ServerError" do
      expect(described_class).to be < VectorMCP::ServerError
    end

    it "has the correct default message" do
      error = described_class.new
      expect(error.message).to eq("Server not initialized")
    end

    it "has the correct error code" do
      error = described_class.new
      expect(error.code).to eq(-32_002)
    end
  end

  describe VectorMCP::NotFoundError do
    let(:error) { described_class.new }

    it "is a subclass of ProtocolError" do # Changed from ServerError
      expect(described_class).to be < VectorMCP::ProtocolError
    end

    it "has the correct default message" do
      expect(error.message).to eq("Not Found")
    end

    it "has the correct error code" do
      expect(error.code).to eq(-32_001)
    end
  end
end
