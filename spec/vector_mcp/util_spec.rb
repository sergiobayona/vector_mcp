# frozen_string_literal: true

require "spec_helper"

RSpec.describe VectorMCP::Util do
  describe ".convert_to_mcp_content" do
    context "with string input" do
      it "converts a single string to text content" do
        result = described_class.convert_to_mcp_content("Hello World")
        expect(result).to eq([{ type: "text", text: "Hello World", mimeType: "text/plain" }])
      end

      it "converts an array of strings to text content" do
        result = described_class.convert_to_mcp_content(%w[Hello World])
        expect(result).to eq([
                               { type: "text", text: "Hello", mimeType: "text/plain" },
                               { type: "text", text: "World", mimeType: "text/plain" }
                             ])
      end
    end

    context "with hash input" do
      it "uses pre-formatted content object as is" do
        content = { type: "text", text: "Hello" }
        result = described_class.convert_to_mcp_content(content)
        expect(result).to eq([content])
      end

      it "converts non-content hash to JSON text" do
        data = { key: "value" }
        result = described_class.convert_to_mcp_content(data)
        expect(result).to eq([{ type: "text", text: data.to_json, mimeType: "application/json" }])
      end

      it "handles different content types" do
        content = { type: "image", data: "base64data", mimeType: "image/png" }
        result = described_class.convert_to_mcp_content(content)
        expect(result).to eq([content])
      end
    end

    context "with binary data" do
      it "converts binary data to text content" do
        binary_data = String.new("binary\x00data").force_encoding(Encoding::ASCII_8BIT)
        result = described_class.convert_to_mcp_content(binary_data)
        expect(result).to eq([{ type: "text", text: binary_data, mimeType: "text/plain" }])
      end
    end

    context "with other input types" do
      it "converts numbers to text" do
        result = described_class.convert_to_mcp_content(42)
        expect(result).to eq([{ type: "text", text: "42", mimeType: "text/plain" }])
      end

      it "converts nil to text" do
        result = described_class.convert_to_mcp_content(nil)
        expect(result).to eq([{ type: "text", text: "", mimeType: "text/plain" }])
      end

      it "converts custom objects to text" do
        custom_obj = Class.new { def to_s = "custom" }.new
        result = described_class.convert_to_mcp_content(custom_obj)
        expect(result).to eq([{ type: "text", text: "custom", mimeType: "text/plain" }])
      end
    end
  end

  describe ".extract_id_from_invalid_json" do
    context "with string IDs" do
      it "extracts string ID from valid JSON" do
        json = '{"id": "123", "method": "test"}'
        expect(described_class.extract_id_from_invalid_json(json)).to eq("123")
      end

      it "extracts string ID with escaped characters" do
        json = '{"id": "123\\"456", "method": "test"}'
        expect(described_class.extract_id_from_invalid_json(json)).to eq('123\\"456')
      end

      it "handles whitespace around ID" do
        json = '{"id" : "123" , "method": "test"}'
        expect(described_class.extract_id_from_invalid_json(json)).to eq("123")
      end
    end

    context "with numeric IDs" do
      it "extracts numeric ID from valid JSON" do
        json = '{"id": 123, "method": "test"}'
        expect(described_class.extract_id_from_invalid_json(json)).to eq(123)
      end

      it "handles whitespace around numeric ID" do
        json = '{"id" : 123 , "method": "test"}'
        expect(described_class.extract_id_from_invalid_json(json)).to eq(123)
      end
    end

    context "with invalid JSON" do
      it "returns nil when no ID field is present" do
        json = '{"method": "test"}'
        expect(described_class.extract_id_from_invalid_json(json)).to be_nil
      end

      it "extracts ID from incomplete JSON" do
        json = '{"id": "123"'
        expect(described_class.extract_id_from_invalid_json(json)).to eq("123")
      end

      it "returns nil for empty string" do
        expect(described_class.extract_id_from_invalid_json("")).to be_nil
      end
    end
  end
end
