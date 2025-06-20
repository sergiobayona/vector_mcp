# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Schema Validation during Tool Registration" do
  let(:server) { VectorMCP.new(name: "SchemaValidationTestServer", version: "1.0.0") }

  describe "valid schemas" do
    it "accepts nil schema" do
      expect do
        server.register_tool(
          name: "no_schema_tool",
          description: "Tool without schema",
          input_schema: nil
        ) { |_args| "ok" }
      end.not_to raise_error
    end

    it "accepts empty schema" do
      expect do
        server.register_tool(
          name: "empty_schema_tool",
          description: "Tool with empty schema",
          input_schema: {}
        ) { |_args| "ok" }
      end.not_to raise_error
    end

    it "accepts valid basic schema" do
      expect do
        server.register_tool(
          name: "basic_tool",
          description: "Tool with basic schema",
          input_schema: {
            "type" => "object",
            "properties" => {
              "message" => { "type" => "string" }
            },
            "required" => ["message"]
          }
        ) { |_args| "ok" }
      end.not_to raise_error
    end

    it "accepts complex valid schema" do
      expect do
        server.register_tool(
          name: "complex_tool",
          description: "Tool with complex schema",
          input_schema: {
            "type" => "object",
            "properties" => {
              "user" => {
                "type" => "object",
                "properties" => {
                  "name" => { "type" => "string", "minLength" => 1 },
                  "age" => { "type" => "integer", "minimum" => 0, "maximum" => 150 },
                  "email" => { "type" => "string", "format" => "email" },
                  "role" => { "type" => "string", "enum" => %w[admin user guest] }
                },
                "required" => %w[name email],
                "additionalProperties" => false
              },
              "tags" => {
                "type" => "array",
                "items" => { "type" => "string" },
                "uniqueItems" => true
              }
            },
            "required" => ["user"],
            "additionalProperties" => false
          }
        ) { |_args| "ok" }
      end.not_to raise_error
    end
  end

  describe "invalid schemas" do
    it "rejects schema with invalid type" do
      expect do
        server.register_tool(
          name: "invalid_type_tool",
          description: "Tool with invalid type",
          input_schema: {
            "type" => "invalid_type",
            "properties" => {
              "message" => { "type" => "string" }
            }
          }
        ) { |_args| "ok" }
      end.to raise_error(ArgumentError, /Invalid input_schema/)
    end

    it "rejects schema with invalid property type" do
      expect do
        server.register_tool(
          name: "invalid_property_tool",
          description: "Tool with invalid property type",
          input_schema: {
            "type" => "object",
            "properties" => {
              "message" => { "type" => "invalid_property_type" }
            }
          }
        ) { |_args| "ok" }
      end.to raise_error(ArgumentError, /Invalid input_schema/)
    end

    it "rejects schema with invalid minimum constraint" do
      expect do
        server.register_tool(
          name: "invalid_minimum_tool",
          description: "Tool with invalid minimum",
          input_schema: {
            "type" => "object",
            "properties" => {
              "age" => { "type" => "integer", "minimum" => "not_a_number" }
            }
          }
        ) { |_args| "ok" }
      end.to raise_error(ArgumentError, /Invalid input_schema/)
    end

    it "rejects schema with invalid required field format" do
      expect do
        server.register_tool(
          name: "invalid_required_tool",
          description: "Tool with invalid required field format",
          input_schema: {
            "type" => "object",
            "properties" => {
              "message" => { "type" => "string" }
            },
            "required" => "should_be_array" # required should be an array
          }
        ) { |_args| "ok" }
      end.to raise_error(ArgumentError, /Invalid input_schema/)
    end

    it "rejects schema with invalid enum format" do
      expect do
        server.register_tool(
          name: "invalid_enum_tool",
          description: "Tool with invalid enum",
          input_schema: {
            "type" => "object",
            "properties" => {
              "role" => { "type" => "string", "enum" => "should_be_array" }
            }
          }
        ) { |_args| "ok" }
      end.to raise_error(ArgumentError, /Invalid input_schema/)
    end

    it "rejects non-hash schema" do
      expect do
        server.register_tool(
          name: "string_schema_tool",
          description: "Tool with string schema",
          input_schema: "not a hash"
        ) { |_args| "ok" }
      end.not_to raise_error # Non-hash schemas are silently ignored
    end

    it "rejects schema with invalid properties format" do
      expect do
        server.register_tool(
          name: "invalid_properties_tool",
          description: "Tool with invalid properties format",
          input_schema: {
            "type" => "object",
            "properties" => "should_be_object" # properties should be an object
          }
        ) { |_args| "ok" }
      end.to raise_error(ArgumentError, /Invalid input_schema/)
    end
  end

  describe "schema validation does not affect tool execution" do
    it "validates schema at registration but not during execution" do
      # Register a tool with valid schema
      server.register_tool(
        name: "execution_test_tool",
        description: "Tool for testing execution after schema validation",
        input_schema: {
          "type" => "object",
          "properties" => {
            "message" => { "type" => "string" }
          },
          "required" => ["message"]
        }
      ) { |args| "Received: #{args["message"]}" }

      # Verify the tool was registered successfully
      expect(server.tools["execution_test_tool"]).to be_a(VectorMCP::Definitions::Tool)

      # The schema validation during registration should not interfere with normal tool operation
      # (Input validation during execution is tested in the integration spec)
      tool = server.tools["execution_test_tool"]
      expect(tool.input_schema).to eq({
                                        "type" => "object",
                                        "properties" => {
                                          "message" => { "type" => "string" }
                                        },
                                        "required" => ["message"]
                                      })
    end
  end

  describe "error messages" do
    it "provides clear error messages for schema format issues" do
      expect do
        server.register_tool(
          name: "bad_format_tool",
          description: "Tool with bad schema format",
          input_schema: {
            "type" => "object",
            "properties" => {
              "invalid" => { "type" => "not_a_valid_type" }
            }
          }
        ) { |_args| "ok" }
      end.to raise_error(ArgumentError) do |error|
        expect(error.message).to include("Invalid input_schema")
        expect(error.message).to match(/format|structure/)
      end
    end
  end
end
