# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Input Schema Validation Integration" do
  describe "JSON Schema validation in tools/call handler" do
    let(:server) { VectorMCP.new(name: "ValidationTestServer", version: "1.0.0") }
    let(:session) { VectorMCP::Session.new(server) }

    before do
      session.initialize!({
                            "protocolVersion" => "2024-11-05",
                            "clientInfo" => { "name" => "test-client", "version" => "1.0.0" },
                            "capabilities" => {}
                          })
    end

    context "String validation" do
      before do
        server.register_tool(
          name: "string_tool",
          description: "Accepts only string parameters",
          input_schema: {
            "type" => "object",
            "properties" => {
              "message" => { "type" => "string", "minLength" => 1 }
            },
            "required" => ["message"],
            "additionalProperties" => false
          }
        ) { |args| "Received: #{args["message"]}" }
      end

      it "accepts valid string parameter" do
        result = server.handle_message({
                                         "jsonrpc" => "2.0",
                                         "id" => 1,
                                         "method" => "tools/call",
                                         "params" => {
                                           "name" => "string_tool",
                                           "arguments" => { "message" => "Hello World" }
                                         }
                                       }, session, "test-session")

        expect(result[:isError]).to be(false)
        expect(result[:content][0][:text]).to eq("Received: Hello World")
      end

      it "rejects missing required parameter" do
        expect do
          server.handle_message({
                                  "jsonrpc" => "2.0",
                                  "id" => 2,
                                  "method" => "tools/call",
                                  "params" => {
                                    "name" => "string_tool",
                                    "arguments" => {}
                                  }
                                }, session, "test-session")
        end.to raise_error(VectorMCP::InvalidParamsError) do |error|
          expect(error.message).to include("Invalid arguments for tool 'string_tool'")
          expect(error.details[:tool]).to eq("string_tool")
          expect(error.details[:validation_errors]).to be_an(Array)
          expect(error.details[:validation_errors].first).to include("required")
        end
      end

      it "rejects empty string (violates minLength)" do
        expect do
          server.handle_message({
                                  "jsonrpc" => "2.0",
                                  "id" => 3,
                                  "method" => "tools/call",
                                  "params" => {
                                    "name" => "string_tool",
                                    "arguments" => { "message" => "" }
                                  }
                                }, session, "test-session")
        end.to raise_error(VectorMCP::InvalidParamsError) do |error|
          expect(error.details[:validation_errors].first).to include("min")
        end
      end

      it "rejects non-string type" do
        expect do
          server.handle_message({
                                  "jsonrpc" => "2.0",
                                  "id" => 4,
                                  "method" => "tools/call",
                                  "params" => {
                                    "name" => "string_tool",
                                    "arguments" => { "message" => 123 }
                                  }
                                }, session, "test-session")
        end.to raise_error(VectorMCP::InvalidParamsError) do |error|
          expect(error.details[:validation_errors].first).to include("type")
        end
      end

      it "rejects additional properties" do
        expect do
          server.handle_message({
                                  "jsonrpc" => "2.0",
                                  "id" => 5,
                                  "method" => "tools/call",
                                  "params" => {
                                    "name" => "string_tool",
                                    "arguments" => {
                                      "message" => "valid",
                                      "extra" => "not allowed"
                                    }
                                  }
                                }, session, "test-session")
        end.to raise_error(VectorMCP::InvalidParamsError) do |error|
          expect(error.details[:validation_errors].first).to include("additional properties")
        end
      end
    end

    context "Number validation" do
      before do
        server.register_tool(
          name: "number_tool",
          description: "Validates number constraints",
          input_schema: {
            "type" => "object",
            "properties" => {
              "age" => { "type" => "integer", "minimum" => 0, "maximum" => 150 },
              "score" => { "type" => "number", "minimum" => 0.0, "maximum" => 100.0 }
            },
            "required" => ["age"],
            "additionalProperties" => false
          }
        ) { |args| "Age: #{args["age"]}, Score: #{args["score"]}" }
      end

      it "accepts valid integer within range" do
        result = server.handle_message({
                                         "jsonrpc" => "2.0",
                                         "id" => 6,
                                         "method" => "tools/call",
                                         "params" => {
                                           "name" => "number_tool",
                                           "arguments" => { "age" => 25 }
                                         }
                                       }, session, "test-session")

        expect(result[:isError]).to be(false)
        expect(result[:content][0][:text]).to include("Age: 25")
      end

      it "accepts optional number parameters" do
        result = server.handle_message({
                                         "jsonrpc" => "2.0",
                                         "id" => 7,
                                         "method" => "tools/call",
                                         "params" => {
                                           "name" => "number_tool",
                                           "arguments" => {
                                             "age" => 30,
                                             "score" => 85.5
                                           }
                                         }
                                       }, session, "test-session")

        expect(result[:isError]).to be(false)
        expect(result[:content][0][:text]).to include("Score: 85.5")
      end

      it "rejects age below minimum" do
        expect do
          server.handle_message({
                                  "jsonrpc" => "2.0",
                                  "id" => 8,
                                  "method" => "tools/call",
                                  "params" => {
                                    "name" => "number_tool",
                                    "arguments" => { "age" => -1 }
                                  }
                                }, session, "test-session")
        end.to raise_error(VectorMCP::InvalidParamsError) do |error|
          expect(error.details[:validation_errors].first).to include("minimum")
        end
      end

      it "rejects age above maximum" do
        expect do
          server.handle_message({
                                  "jsonrpc" => "2.0",
                                  "id" => 9,
                                  "method" => "tools/call",
                                  "params" => {
                                    "name" => "number_tool",
                                    "arguments" => { "age" => 200 }
                                  }
                                }, session, "test-session")
        end.to raise_error(VectorMCP::InvalidParamsError) do |error|
          expect(error.details[:validation_errors].first).to include("maximum")
        end
      end

      it "rejects string when number expected" do
        expect do
          server.handle_message({
                                  "jsonrpc" => "2.0",
                                  "id" => 10,
                                  "method" => "tools/call",
                                  "params" => {
                                    "name" => "number_tool",
                                    "arguments" => { "age" => "twenty-five" }
                                  }
                                }, session, "test-session")
        end.to raise_error(VectorMCP::InvalidParamsError) do |error|
          expect(error.details[:validation_errors].first).to include("type")
        end
      end
    end

    context "Array and enum validation" do
      before do
        server.register_tool(
          name: "array_tool",
          description: "Validates arrays and enums",
          input_schema: {
            "type" => "object",
            "properties" => {
              "tags" => {
                "type" => "array",
                "items" => { "type" => "string" },
                "minItems" => 1,
                "maxItems" => 5,
                "uniqueItems" => true
              },
              "priority" => {
                "type" => "string",
                "enum" => %w[low medium high critical]
              }
            },
            "required" => %w[tags priority],
            "additionalProperties" => false
          }
        ) { |args| "Tags: #{args["tags"].join(", ")}, Priority: #{args["priority"]}" }
      end

      it "accepts valid array and enum" do
        result = server.handle_message({
                                         "jsonrpc" => "2.0",
                                         "id" => 11,
                                         "method" => "tools/call",
                                         "params" => {
                                           "name" => "array_tool",
                                           "arguments" => {
                                             "tags" => %w[urgent bug frontend],
                                             "priority" => "high"
                                           }
                                         }
                                       }, session, "test-session")

        expect(result[:isError]).to be(false)
        expect(result[:content][0][:text]).to include("Tags: urgent, bug, frontend")
        expect(result[:content][0][:text]).to include("Priority: high")
      end

      it "rejects empty array (violates minItems)" do
        expect do
          server.handle_message({
                                  "jsonrpc" => "2.0",
                                  "id" => 12,
                                  "method" => "tools/call",
                                  "params" => {
                                    "name" => "array_tool",
                                    "arguments" => {
                                      "tags" => [],
                                      "priority" => "medium"
                                    }
                                  }
                                }, session, "test-session")
        end.to raise_error(VectorMCP::InvalidParamsError) do |error|
          expect(error.details[:validation_errors].first).to include("min")
        end
      end

      it "rejects array with too many items" do
        expect do
          server.handle_message({
                                  "jsonrpc" => "2.0",
                                  "id" => 13,
                                  "method" => "tools/call",
                                  "params" => {
                                    "name" => "array_tool",
                                    "arguments" => {
                                      "tags" => %w[one two three four five six],
                                      "priority" => "medium"
                                    }
                                  }
                                }, session, "test-session")
        end.to raise_error(VectorMCP::InvalidParamsError) do |error|
          expect(error.details[:validation_errors].first).to include("more items than")
        end
      end

      it "rejects invalid enum value" do
        expect do
          server.handle_message({
                                  "jsonrpc" => "2.0",
                                  "id" => 14,
                                  "method" => "tools/call",
                                  "params" => {
                                    "name" => "array_tool",
                                    "arguments" => {
                                      "tags" => ["valid"],
                                      "priority" => "super-urgent"
                                    }
                                  }
                                }, session, "test-session")
        end.to raise_error(VectorMCP::InvalidParamsError) do |error|
          expect(error.details[:validation_errors].first).to include("did not match one of")
        end
      end
    end

    context "Nested object validation" do
      before do
        server.register_tool(
          name: "nested_tool",
          description: "Validates nested objects",
          input_schema: {
            "type" => "object",
            "properties" => {
              "user" => {
                "type" => "object",
                "properties" => {
                  "name" => { "type" => "string", "minLength" => 1 },
                  "email" => { "type" => "string", "format" => "email" },
                  "settings" => {
                    "type" => "object",
                    "properties" => {
                      "theme" => { "type" => "string", "enum" => %w[light dark] },
                      "notifications" => { "type" => "boolean" }
                    },
                    "required" => ["theme"],
                    "additionalProperties" => false
                  }
                },
                "required" => %w[name email],
                "additionalProperties" => false
              }
            },
            "required" => ["user"],
            "additionalProperties" => false
          }
        ) { |args| "User: #{args["user"]["name"]} (#{args["user"]["email"]})" }
      end

      it "accepts complete valid nested object" do
        result = server.handle_message({
                                         "jsonrpc" => "2.0",
                                         "id" => 15,
                                         "method" => "tools/call",
                                         "params" => {
                                           "name" => "nested_tool",
                                           "arguments" => {
                                             "user" => {
                                               "name" => "Alice Smith",
                                               "email" => "alice@example.com",
                                               "settings" => {
                                                 "theme" => "dark",
                                                 "notifications" => true
                                               }
                                             }
                                           }
                                         }
                                       }, session, "test-session")

        expect(result[:isError]).to be(false)
        expect(result[:content][0][:text]).to include("User: Alice Smith (alice@example.com)")
      end

      it "rejects missing required nested field" do
        expect do
          server.handle_message({
                                  "jsonrpc" => "2.0",
                                  "id" => 16,
                                  "method" => "tools/call",
                                  "params" => {
                                    "name" => "nested_tool",
                                    "arguments" => {
                                      "user" => {
                                        "name" => "Charlie",
                                        # Missing required email
                                        "settings" => {
                                          "theme" => "light"
                                        }
                                      }
                                    }
                                  }
                                }, session, "test-session")
        end.to raise_error(VectorMCP::InvalidParamsError) do |error|
          expect(error.details[:validation_errors].first).to include("required")
          expect(error.details[:validation_errors].first).to include("email")
        end
      end

      it "rejects invalid enum in nested object" do
        expect do
          server.handle_message({
                                  "jsonrpc" => "2.0",
                                  "id" => 17,
                                  "method" => "tools/call",
                                  "params" => {
                                    "name" => "nested_tool",
                                    "arguments" => {
                                      "user" => {
                                        "name" => "Eve",
                                        "email" => "eve@example.com",
                                        "settings" => {
                                          "theme" => "rainbow" # Invalid enum value
                                        }
                                      }
                                    }
                                  }
                                }, session, "test-session")
        end.to raise_error(VectorMCP::InvalidParamsError) do |error|
          expect(error.details[:validation_errors].first).to include("did not match one of")
        end
      end
    end

    context "Optional parameters" do
      before do
        server.register_tool(
          name: "optional_tool",
          description: "Tool with optional parameters",
          input_schema: {
            "type" => "object",
            "properties" => {
              "required_param" => { "type" => "string" },
              "optional_string" => { "type" => "string" },
              "optional_number" => { "type" => "integer" }
            },
            "required" => ["required_param"],
            "additionalProperties" => true # Allow additional properties
          }
        ) { |args| "Required: #{args["required_param"]}, Optional keys: #{args.keys.sort}" }
      end

      it "accepts only required parameter" do
        result = server.handle_message({
                                         "jsonrpc" => "2.0",
                                         "id" => 18,
                                         "method" => "tools/call",
                                         "params" => {
                                           "name" => "optional_tool",
                                           "arguments" => { "required_param" => "value" }
                                         }
                                       }, session, "test-session")

        expect(result[:isError]).to be(false)
        expect(result[:content][0][:text]).to include("Required: value")
      end

      it "accepts additional properties when allowed" do
        result = server.handle_message({
                                         "jsonrpc" => "2.0",
                                         "id" => 19,
                                         "method" => "tools/call",
                                         "params" => {
                                           "name" => "optional_tool",
                                           "arguments" => {
                                             "required_param" => "value",
                                             "extra_field" => "allowed because additionalProperties: true"
                                           }
                                         }
                                       }, session, "test-session")

        expect(result[:isError]).to be(false)
        expect(result[:content][0][:text]).to include("Required: value")
      end

      it "rejects missing required parameter even with optionals present" do
        expect do
          server.handle_message({
                                  "jsonrpc" => "2.0",
                                  "id" => 20,
                                  "method" => "tools/call",
                                  "params" => {
                                    "name" => "optional_tool",
                                    "arguments" => {
                                      "optional_string" => "present",
                                      "optional_number" => 123
                                      # Missing required_param
                                    }
                                  }
                                }, session, "test-session")
        end.to raise_error(VectorMCP::InvalidParamsError) do |error|
          expect(error.details[:validation_errors].first).to include("required")
          expect(error.details[:validation_errors].first).to include("required_param")
        end
      end
    end

    context "Tools without schemas" do
      before do
        # Tool with no schema (should skip validation)
        server.register_tool(
          name: "no_schema_tool",
          description: "Tool without input schema - should accept anything",
          input_schema: nil
        ) { |args| "Accepted anything: #{args.keys.join(", ")}" }

        # Tool with empty schema (should skip validation)
        server.register_tool(
          name: "empty_schema_tool",
          description: "Tool with empty schema",
          input_schema: {}
        ) { |args| "Empty schema accepted: #{args.keys.join(", ")}" }
      end

      it "accepts any input for tool with no schema" do
        result = server.handle_message({
                                         "jsonrpc" => "2.0",
                                         "id" => 21,
                                         "method" => "tools/call",
                                         "params" => {
                                           "name" => "no_schema_tool",
                                           "arguments" => {
                                             "anything" => "goes",
                                             "numbers" => 123,
                                             "arrays" => [1, 2, 3],
                                             "objects" => { "nested" => true }
                                           }
                                         }
                                       }, session, "test-session")

        expect(result[:isError]).to be(false)
        expect(result[:content][0][:text]).to include("Accepted anything:")
      end

      it "accepts any input for tool with empty schema" do
        result = server.handle_message({
                                         "jsonrpc" => "2.0",
                                         "id" => 22,
                                         "method" => "tools/call",
                                         "params" => {
                                           "name" => "empty_schema_tool",
                                           "arguments" => {
                                             "also_anything" => "works",
                                             "even_invalid_types" => { "complex" => %w[data structures] }
                                           }
                                         }
                                       }, session, "test-session")

        expect(result[:isError]).to be(false)
        expect(result[:content][0][:text]).to include("Empty schema accepted:")
      end
    end

    context "Error handling and edge cases" do
      before do
        server.register_tool(
          name: "strict_tool",
          description: "Tool for testing detailed error reporting",
          input_schema: {
            "type" => "object",
            "properties" => {
              "name" => { "type" => "string" },
              "age" => { "type" => "integer", "minimum" => 0 }
            },
            "required" => %w[name age],
            "additionalProperties" => false
          }
        ) { |args| "Valid input: #{args}" }
      end

      it "provides detailed error messages for validation failures" do
        expect do
          server.handle_message({
                                  "jsonrpc" => "2.0",
                                  "id" => 23,
                                  "method" => "tools/call",
                                  "params" => {
                                    "name" => "strict_tool",
                                    "arguments" => { "name" => 123 } # Wrong type and missing required field
                                  }
                                }, session, "test-session")
        end.to raise_error(VectorMCP::InvalidParamsError) do |error|
          expect(error.message).to include("Invalid arguments for tool 'strict_tool'")
          expect(error.details).to have_key(:tool)
          expect(error.details[:tool]).to eq("strict_tool")
          expect(error.details).to have_key(:validation_errors)
          expect(error.details[:validation_errors]).to be_an(Array)
          expect(error.details).to have_key(:message)
          expect(error.details[:message]).to be_a(String)
        end
      end

      it "handles complex validation combinations" do
        expect do
          server.handle_message({
                                  "jsonrpc" => "2.0",
                                  "id" => 24,
                                  "method" => "tools/call",
                                  "params" => {
                                    "name" => "strict_tool",
                                    "arguments" => {
                                      "name" => 456, # Type error
                                      "age" => -5,                # Range error
                                      "extra_field" => "invalid"  # Additional property error
                                    }
                                  }
                                }, session, "test-session")
        end.to raise_error(VectorMCP::InvalidParamsError) do |error|
          # Should report multiple validation errors
          expect(error.details[:validation_errors].length).to be > 1
        end
      end
    end
  end
end
