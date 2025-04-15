# frozen_string_literal: true

require "spec_helper"

RSpec.describe VectorMCP::Definitions do
  describe VectorMCP::Definitions::Tool do
    subject(:tool) do
      described_class.new(tool_name, tool_description, tool_input_schema, tool_handler)
    end

    let(:tool_name) { "test_tool" }
    let(:tool_description) { "A test tool" }
    let(:tool_input_schema) { { type: "object", properties: { name: { type: "string" } } } }
    let(:tool_handler) { proc { |input| input } }

    describe "#as_mcp_definition" do
      it "returns a hash with the correct structure" do
        expected = {
          name: tool_name,
          description: tool_description,
          inputSchema: tool_input_schema
        }

        expect(tool.as_mcp_definition).to eq(expected)
      end

      it "removes nil values from the hash" do
        tool_with_nil = described_class.new(tool_name, nil, tool_input_schema, tool_handler)
        expected = {
          name: tool_name,
          inputSchema: tool_input_schema
        }

        expect(tool_with_nil.as_mcp_definition).to eq(expected)
      end
    end
  end

  describe VectorMCP::Definitions::Resource do
    subject(:resource) do
      described_class.new(resource_uri, resource_name, resource_description, resource_mime_type, resource_handler)
    end

    let(:resource_uri) { URI.parse("https://example.com/resource") }
    let(:resource_name) { "test_resource" }
    let(:resource_description) { "A test resource" }
    let(:resource_mime_type) { "application/json" }
    let(:resource_handler) { proc { |input| input } }

    describe "#as_mcp_definition" do
      it "returns a hash with the correct structure" do
        expected = {
          uri: resource_uri.to_s,
          name: resource_name,
          description: resource_description,
          mimeType: resource_mime_type
        }

        expect(resource.as_mcp_definition).to eq(expected)
      end

      it "removes nil values from the hash" do
        resource_with_nil = described_class.new(resource_uri, resource_name, nil, nil, resource_handler)
        expected = {
          uri: resource_uri.to_s,
          name: resource_name
        }

        expect(resource_with_nil.as_mcp_definition).to eq(expected)
      end
    end
  end

  describe VectorMCP::Definitions::Prompt do
    subject(:prompt) do
      described_class.new(prompt_name, prompt_description, prompt_arguments, prompt_handler)
    end

    let(:prompt_name) { "test_prompt" }
    let(:prompt_description) { "A test prompt" }
    let(:prompt_arguments) do
      [
        { name: "arg1", description: "First argument", required: true },
        { name: "arg2", description: "Second argument", required: false }
      ]
    end
    let(:prompt_handler) { proc { |input| input } }

    describe "#as_mcp_definition" do
      it "returns a hash with the correct structure" do
        expected = {
          name: prompt_name,
          description: prompt_description,
          arguments: prompt_arguments
        }

        expect(prompt.as_mcp_definition).to eq(expected)
      end

      it "removes nil values from the hash" do
        prompt_with_nil = described_class.new(prompt_name, nil, nil, prompt_handler)
        expected = {
          name: prompt_name
        }

        expect(prompt_with_nil.as_mcp_definition).to eq(expected)
      end
    end
  end
end
