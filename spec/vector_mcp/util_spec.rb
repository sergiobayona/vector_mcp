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

      context "with image file paths" do
        let(:temp_image_file) { Tempfile.new(["test", ".jpg"]) }
        let(:jpeg_data) { "#{[0xFF, 0xD8, 0xFF, 0xE0].pack("C*")}jpeg content" }

        before do
          temp_image_file.binmode
          temp_image_file.write(jpeg_data)
          temp_image_file.close
        end

        after do
          temp_image_file.unlink
        end

        it "detects and processes image file paths" do
          result = described_class.convert_to_mcp_content(temp_image_file.path)

          expect(result).to be_an(Array)
          expect(result.length).to eq(1)
          expect(result.first[:type]).to eq("image")
          expect(result.first[:mimeType]).to eq("image/jpeg")
          expect(result.first[:data]).to be_a(String)
        end

        it "handles non-existent image files gracefully" do
          result = described_class.convert_to_mcp_content("/path/to/nonexistent/image.jpg")

          expect(result).to be_an(Array)
          expect(result.length).to eq(1)
          expect(result.first[:type]).to eq("text")
          expect(result.first[:text]).to include("Error loading image")
        end
      end

      context "with binary image data" do
        let(:jpeg_data) { "#{[0xFF, 0xD8, 0xFF, 0xE0].pack("C*")}jpeg content" }

        it "detects and processes binary image data" do
          binary_jpeg = jpeg_data.dup.force_encoding(Encoding::ASCII_8BIT)
          result = described_class.convert_to_mcp_content(binary_jpeg)

          expect(result).to be_an(Array)
          expect(result.length).to eq(1)
          expect(result.first[:type]).to eq("image")
          expect(result.first[:mimeType]).to eq("image/jpeg")
          expect(result.first[:data]).to be_a(String)
        end

        it "falls back to text for non-image binary data" do
          binary_data = "random binary\x00\x01\x02".dup.force_encoding(Encoding::ASCII_8BIT)
          result = described_class.convert_to_mcp_content(binary_data)

          expect(result).to be_an(Array)
          expect(result.length).to eq(1)
          expect(result.first[:type]).to eq("text")
          expect(result.first[:mimeType]).to eq("text/plain")
        end
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
        valid_base64 = VectorMCP::ImageUtil.encode_base64("test image data")
        content = { type: "image", data: valid_base64, mimeType: "image/png" }
        result = described_class.convert_to_mcp_content(content)
        expect(result).to eq([content])
      end

      context "with image content" do
        let(:valid_base64) { VectorMCP::ImageUtil.encode_base64("fake image data") }

        it "validates and enhances image content" do
          image_content = {
            type: "image",
            data: valid_base64,
            mimeType: "image/jpeg"
          }

          result = described_class.convert_to_mcp_content(image_content)
          expect(result).to be_an(Array)
          expect(result.length).to eq(1)
          expect(result.first[:type]).to eq("image")
          expect(result.first[:data]).to eq(valid_base64)
          expect(result.first[:mimeType]).to eq("image/jpeg")
        end

        it "raises error for invalid image content" do
          invalid_image_content = {
            type: "image",
            data: "invalid base64!",
            mimeType: "image/jpeg"
          }

          expect do
            described_class.convert_to_mcp_content(invalid_image_content)
          end.to raise_error(ArgumentError, /Invalid base64 image data/)
        end

        it "raises error for incomplete image content" do
          incomplete_image_content = { type: "image", data: valid_base64 }
          # Missing mimeType

          expect do
            described_class.convert_to_mcp_content(incomplete_image_content)
          end.to raise_error(ArgumentError, /must have both :data and :mimeType fields/)
        end
      end
    end

    context "with array input" do
      context "with pre-formatted content items" do
        it "handles mixed content types" do
          content_array = [
            { type: "text", text: "Hello" },
            { type: "image", data: VectorMCP::ImageUtil.encode_base64("fake"), mimeType: "image/png" }
          ]

          result = described_class.convert_to_mcp_content(content_array)
          expect(result).to be_an(Array)
          expect(result.length).to eq(2)
          expect(result[0][:type]).to eq("text")
          expect(result[1][:type]).to eq("image")
        end

        it "validates image content in arrays" do
          invalid_array = [
            { type: "text", text: "Hello" },
            { type: "image", data: "invalid!", mimeType: "image/png" }
          ]

          expect do
            described_class.convert_to_mcp_content(invalid_array)
          end.to raise_error(ArgumentError, /Invalid base64 image data/)
        end
      end

      context "with mixed raw data" do
        let(:jpeg_data) { "#{[0xFF, 0xD8, 0xFF, 0xE0].pack("C*")}content" }

        it "recursively converts each item" do
          mixed_array = ["text", jpeg_data.dup.force_encoding(Encoding::ASCII_8BIT)]

          result = described_class.convert_to_mcp_content(mixed_array)
          expect(result).to be_an(Array)
          expect(result.length).to eq(2)
          expect(result[0][:type]).to eq("text")
          expect(result[1][:type]).to eq("image")
        end
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
        json = '{"jsonrpc": "2.0", "id": 123, "method": "test"}'
        expect(described_class.extract_id_from_invalid_json(json)).to eq("123")
      end

      it "handles whitespace around numeric ID" do
        json = '{"id" : 123 , "method": "test"}'
        expect(described_class.extract_id_from_invalid_json(json)).to eq("123")
      end
    end

    context "with no ID found" do
      it "returns nil when no ID is present" do
        json = '{"method": "test", "params": {}}'
        expect(described_class.extract_id_from_invalid_json(json)).to be_nil
      end

      it "returns nil for invalid JSON" do
        json = '{"incomplete":'
        expect(described_class.extract_id_from_invalid_json(json)).to be_nil
      end
    end
  end

  describe "image file path detection" do
    describe ".looks_like_image_file_path?" do
      it "identifies common image file extensions" do
        %w[.jpg .jpeg .png .gif .webp .bmp .tiff .tif .svg].each do |ext|
          expect(described_class.looks_like_image_file_path?("image#{ext}")).to be true
          expect(described_class.looks_like_image_file_path?("IMAGE#{ext.upcase}")).to be true
        end
      end

      it "requires path-like structure" do
        expect(described_class.looks_like_image_file_path?("image.jpg")).to be true
        expect(described_class.looks_like_image_file_path?("/path/to/image.jpg")).to be true
        expect(described_class.looks_like_image_file_path?("C:\\images\\photo.png")).to be true
      end

      it "rejects non-image extensions" do
        expect(described_class.looks_like_image_file_path?("document.pdf")).to be false
        expect(described_class.looks_like_image_file_path?("script.js")).to be false
        expect(described_class.looks_like_image_file_path?("style.css")).to be false
      end

      it "rejects overly long strings" do
        long_path = "#{"a" * 600}.jpg"
        expect(described_class.looks_like_image_file_path?(long_path)).to be false
      end

      it "handles edge cases" do
        expect(described_class.looks_like_image_file_path?(nil)).to be false
        expect(described_class.looks_like_image_file_path?("")).to be false
        expect(described_class.looks_like_image_file_path?("just text")).to be false
      end
    end
  end

  describe "binary image data detection" do
    describe ".binary_image_data?" do
      let(:jpeg_signature) { [0xFF, 0xD8, 0xFF, 0xE0].pack("C*") }
      let(:png_signature) { [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A].pack("C*") }

      it "detects JPEG binary data" do
        jpeg_data = "#{jpeg_signature}jpeg content".force_encoding(Encoding::ASCII_8BIT)
        expect(described_class.binary_image_data?(jpeg_data)).to be true
      end

      it "detects PNG binary data" do
        png_data = "#{png_signature}png content".force_encoding(Encoding::ASCII_8BIT)
        expect(described_class.binary_image_data?(png_data)).to be true
      end

      it "rejects non-binary data" do
        text_data = "Hello, World!"
        expect(described_class.binary_image_data?(text_data)).to be false
      end

      it "rejects binary non-image data" do
        binary_data = "random\x00\x01\x02".dup.force_encoding(Encoding::ASCII_8BIT)
        expect(described_class.binary_image_data?(binary_data)).to be false
      end

      it "handles edge cases" do
        expect(described_class.binary_image_data?(nil)).to be false
        expect(described_class.binary_image_data?("")).to be false
      end
    end
  end

  describe "image content validation" do
    describe ".validate_and_enhance_image_content" do
      let(:valid_base64) { VectorMCP::ImageUtil.encode_base64("test data") }

      it "validates complete image content" do
        content = {
          type: "image",
          data: valid_base64,
          mimeType: "image/jpeg"
        }

        result = described_class.validate_and_enhance_image_content(content)
        expect(result).to eq(content)
      end

      it "raises error for missing data field" do
        content = {
          type: "image",
          mimeType: "image/jpeg"
        }

        expect do
          described_class.validate_and_enhance_image_content(content)
        end.to raise_error(ArgumentError, /must have both :data and :mimeType fields/)
      end

      it "raises error for missing mimeType field" do
        content = {
          type: "image",
          data: valid_base64
        }

        expect do
          described_class.validate_and_enhance_image_content(content)
        end.to raise_error(ArgumentError, /must have both :data and :mimeType fields/)
      end

      it "raises error for invalid base64 data" do
        content = {
          type: "image",
          data: "invalid base64!",
          mimeType: "image/jpeg"
        }

        expect do
          described_class.validate_and_enhance_image_content(content)
        end.to raise_error(ArgumentError, /Invalid base64 image data/)
      end
    end
  end

  describe "integration with image conversion" do
    let(:temp_dir) { Dir.mktmpdir }
    let(:image_file) { File.join(temp_dir, "test.jpg") }
    let(:jpeg_data) { "#{[0xFF, 0xD8, 0xFF, 0xE0].pack("C*")}jpeg content" }

    before do
      File.binwrite(image_file, jpeg_data)
    end

    after do
      FileUtils.rm_rf(temp_dir)
    end

    it "handles complete workflow from file path to MCP content" do
      result = described_class.convert_to_mcp_content(image_file)

      expect(result).to be_an(Array)
      expect(result.length).to eq(1)

      content = result.first
      expect(content[:type]).to eq("image")
      expect(content[:mimeType]).to eq("image/jpeg")
      expect(content[:data]).to be_a(String)

      # Verify round-trip
      decoded = VectorMCP::ImageUtil.decode_base64(content[:data])
      expect(decoded).to eq(jpeg_data)
    end

    it "handles binary data conversion" do
      binary_jpeg = jpeg_data.dup.force_encoding(Encoding::ASCII_8BIT)
      result = described_class.convert_to_mcp_content(binary_jpeg)

      expect(result).to be_an(Array)
      expect(result.length).to eq(1)

      content = result.first
      expect(content[:type]).to eq("image")
      expect(content[:mimeType]).to eq("image/jpeg")

      # Verify round-trip
      decoded = VectorMCP::ImageUtil.decode_base64(content[:data])
      expect(decoded).to eq(binary_jpeg)
    end

    it "handles mixed content arrays with images" do
      mixed_content = [
        "Hello, World!",
        image_file,
        { type: "text", text: "More text" },
        binary_jpeg = jpeg_data.dup.force_encoding(Encoding::ASCII_8BIT)
      ]

      result = described_class.convert_to_mcp_content(mixed_content)

      expect(result).to be_an(Array)
      expect(result.length).to eq(4)

      expect(result[0][:type]).to eq("text")
      expect(result[1][:type]).to eq("image")  # File path converted
      expect(result[2][:type]).to eq("text")
      expect(result[3][:type]).to eq("image")  # Binary data converted
    end
  end
end
