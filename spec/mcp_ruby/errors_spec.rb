# frozen_string_literal: true

require "spec_helper"

RSpec.describe "MCPRuby Errors" do
  describe MCPRuby::Error do
    it "is a subclass of StandardError" do
      expect(described_class).to be < StandardError
    end
  end

  describe MCPRuby::ProtocolError do
    let(:message) { "Test error message" }
    let(:code) { -32_000 }
    let(:request_id) { "123" }
    let(:details) { { foo: "bar" } }

    subject(:error) do
      described_class.new(message, code: code, request_id: request_id, details: details)
    end

    it "is a subclass of MCPRuby::Error" do
      expect(described_class).to be < MCPRuby::Error
    end

    it "has the correct attributes" do
      expect(error.message).to eq(message)
      expect(error.code).to eq(code)
      expect(error.request_id).to eq(request_id)
      expect(error.details).to eq(details)
    end

    context "when optional parameters are not provided" do
      subject(:error) { described_class.new(message, code: code) }

      it "sets request_id to nil" do
        expect(error.request_id).to be_nil
      end

      it "sets details to nil" do
        expect(error.details).to be_nil
      end
    end
  end

  describe MCPRuby::ParseError do
    let(:request_id) { "123" }
    let(:details) { { line: 42 } }

    it "is a subclass of ProtocolError" do
      expect(described_class).to be < MCPRuby::ProtocolError
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

  describe MCPRuby::InvalidRequestError do
    it "is a subclass of ProtocolError" do
      expect(described_class).to be < MCPRuby::ProtocolError
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

  describe MCPRuby::MethodNotFoundError do
    let(:method_name) { "nonexistent_method" }

    it "is a subclass of ProtocolError" do
      expect(described_class).to be < MCPRuby::ProtocolError
    end

    it "has the correct default message" do
      error = described_class.new(method_name)
      expect(error.message).to eq("Method not found")
    end

    it "has the correct error code" do
      error = described_class.new(method_name)
      expect(error.code).to eq(-32_601)
    end

    it "includes the method name in details" do
      error = described_class.new(method_name)
      expect(error.details).to eq({ method: method_name })
    end
  end

  describe MCPRuby::InvalidParamsError do
    it "is a subclass of ProtocolError" do
      expect(described_class).to be < MCPRuby::ProtocolError
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

  describe MCPRuby::InternalError do
    it "is a subclass of ProtocolError" do
      expect(described_class).to be < MCPRuby::ProtocolError
    end

    it "has the correct default message" do
      error = described_class.new
      expect(error.message).to eq("Internal server error")
    end

    it "has the correct error code" do
      error = described_class.new
      expect(error.code).to eq(-32_603)
    end
  end

  describe MCPRuby::ServerError do
    let(:message) { "Custom server error" }
    let(:code) { -32_000 }
    let(:request_id) { "123" }
    let(:details) { { error: "details" } }

    it "is a subclass of ProtocolError" do
      expect(described_class).to be < MCPRuby::ProtocolError
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
  end

  describe MCPRuby::InitializationError do
    it "is a subclass of ServerError" do
      expect(described_class).to be < MCPRuby::ServerError
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

  describe MCPRuby::NotFoundError do
    it "is a subclass of ServerError" do
      expect(described_class).to be < MCPRuby::ServerError
    end

    it "has the correct default message" do
      error = described_class.new
      expect(error.message).to eq("Not Found")
    end

    it "has the correct error code" do
      error = described_class.new
      expect(error.code).to eq(-32_001)
    end
  end
end
