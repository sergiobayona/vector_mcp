# frozen_string_literal: true

require "spec_helper"

RSpec.describe VectorMCP::ImageUtil do
  describe ".detect_image_format" do
    context "with JPEG data" do
      let(:jpeg_data) { "#{[0xFF, 0xD8, 0xFF, 0xE0].pack("C*")}some data" }

      it "detects JPEG format" do
        expect(described_class.detect_image_format(jpeg_data)).to eq("image/jpeg")
      end
    end

    context "with PNG data" do
      let(:png_data) { "#{[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A].pack("C*")}PNG data" }

      it "detects PNG format" do
        expect(described_class.detect_image_format(png_data)).to eq("image/png")
      end
    end

    context "with GIF data" do
      let(:gif87a_data) { "GIF87asome gif data" }
      let(:gif89a_data) { "GIF89asome gif data" }

      it "detects GIF87a format" do
        expect(described_class.detect_image_format(gif87a_data)).to eq("image/gif")
      end

      it "detects GIF89a format" do
        expect(described_class.detect_image_format(gif89a_data)).to eq("image/gif")
      end
    end

    context "with WebP data" do
      let(:webp_data) { "RIFF#{[12].pack("V")}WEBPVP8 " }

      it "detects WebP format" do
        expect(described_class.detect_image_format(webp_data)).to eq("image/webp")
      end
    end

    context "with BMP data" do
      let(:bmp_data) { "BMbitmap data" }

      it "detects BMP format" do
        expect(described_class.detect_image_format(bmp_data)).to eq("image/bmp")
      end
    end

    context "with TIFF data" do
      let(:tiff_le_data) { "II*\u0000tiff data" }
      let(:tiff_be_data) { "MM\u0000*tiff data" }

      it "detects little-endian TIFF format" do
        expect(described_class.detect_image_format(tiff_le_data)).to eq("image/tiff")
      end

      it "detects big-endian TIFF format" do
        expect(described_class.detect_image_format(tiff_be_data)).to eq("image/tiff")
      end
    end

    context "with invalid data" do
      it "returns nil for empty data" do
        expect(described_class.detect_image_format("")).to be_nil
        expect(described_class.detect_image_format(nil)).to be_nil
      end

      it "returns nil for non-image data" do
        expect(described_class.detect_image_format("just text")).to be_nil
        expect(described_class.detect_image_format("PDF-1.4")).to be_nil
      end
    end
  end

  describe ".validate_image" do
    let(:valid_jpeg) { "#{[0xFF, 0xD8, 0xFF, 0xE0].pack("C*")}jpeg content" }
    let(:valid_png) { "#{[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A].pack("C*")}png content" }

    context "with valid image data" do
      it "validates JPEG data successfully" do
        result = described_class.validate_image(valid_jpeg)
        expect(result[:valid]).to be true
        expect(result[:mime_type]).to eq("image/jpeg")
        expect(result[:size]).to eq(valid_jpeg.bytesize)
        expect(result[:errors]).to be_empty
      end

      it "validates PNG data successfully" do
        result = described_class.validate_image(valid_png)
        expect(result[:valid]).to be true
        expect(result[:mime_type]).to eq("image/png")
        expect(result[:errors]).to be_empty
      end
    end

    context "with size restrictions" do
      it "rejects images that are too large" do
        result = described_class.validate_image(valid_jpeg, max_size: 5)
        expect(result[:valid]).to be false
        expect(result[:errors]).to include(/exceeds maximum allowed size/)
      end

      it "accepts images within size limit" do
        result = described_class.validate_image(valid_jpeg, max_size: 1000)
        expect(result[:valid]).to be true
      end
    end

    context "with format restrictions" do
      it "rejects disallowed formats" do
        result = described_class.validate_image(valid_jpeg, allowed_formats: ["image/png"])
        expect(result[:valid]).to be false
        expect(result[:errors]).to include(/is not allowed/)
      end

      it "accepts allowed formats" do
        result = described_class.validate_image(valid_jpeg, allowed_formats: ["image/jpeg", "image/png"])
        expect(result[:valid]).to be true
      end
    end

    context "with invalid data" do
      it "rejects empty data" do
        result = described_class.validate_image("")
        expect(result[:valid]).to be false
        expect(result[:errors]).to include("Image data is empty")
      end

      it "rejects nil data" do
        result = described_class.validate_image(nil)
        expect(result[:valid]).to be false
        expect(result[:errors]).to include("Image data is empty")
      end

      it "rejects non-image data" do
        result = described_class.validate_image("just text")
        expect(result[:valid]).to be false
        expect(result[:errors]).to include("Unrecognized or invalid image format")
      end
    end
  end

  describe ".encode_base64 and .decode_base64" do
    let(:test_data) { "Hello, World! 🌍" }
    let(:base64_encoded) { "SGVsbG8sIFdvcmxkISDwn42N" }

    describe ".encode_base64" do
      it "encodes data to base64" do
        result = described_class.encode_base64(test_data)
        expect(result).to be_a(String)
        expect(result).to match(%r{\A[A-Za-z0-9+/]*={0,2}\z})
      end

      it "produces decodable output" do
        encoded = described_class.encode_base64(test_data)
        decoded = described_class.decode_base64(encoded)
        expect(decoded).to eq(test_data.dup.force_encoding(Encoding::ASCII_8BIT))
      end
    end

    describe ".decode_base64" do
      it "decodes valid base64 data" do
        result = described_class.decode_base64(base64_encoded)
        expect(result).to be_a(String)
      end

      it "raises error for invalid base64" do
        expect do
          described_class.decode_base64("invalid base64!")
        end.to raise_error(ArgumentError, /Invalid base64 encoding/)
      end
    end
  end

  describe ".base64_string?" do
    it "identifies valid base64 strings" do
      expect(described_class.base64_string?("SGVsbG8=")).to be true
      expect(described_class.base64_string?("SGVsbG8")).to be true
      expect(described_class.base64_string?("SGVsbG8gV29ybGQ=")).to be true
    end

    it "rejects invalid base64 strings" do
      expect(described_class.base64_string?("Hello World!")).to be false
      expect(described_class.base64_string?("SGVsb@8=")).to be false # Invalid character
      expect(described_class.base64_string?("SGVsb===")).to be false # Too much padding
      expect(described_class.base64_string?("SGVs")).to be false # Wrong length
    end

    it "handles edge cases" do
      expect(described_class.base64_string?(nil)).to be false
      expect(described_class.base64_string?("")).to be false
    end
  end

  describe ".to_mcp_image_content" do
    let(:jpeg_data) { "#{[0xFF, 0xD8, 0xFF, 0xE0].pack("C*")}jpeg content" }
    let(:encoded_jpeg) { described_class.encode_base64(jpeg_data) }

    context "with binary image data" do
      it "converts binary data to MCP format" do
        result = described_class.to_mcp_image_content(jpeg_data)

        expect(result).to be_a(Hash)
        expect(result[:type]).to eq("image")
        expect(result[:data]).to be_a(String)
        expect(result[:mimeType]).to eq("image/jpeg")

        # Verify data is base64 encoded
        expect(described_class.base64_string?(result[:data])).to be true
      end

      it "validates data by default" do
        expect do
          described_class.to_mcp_image_content("invalid image data")
        end.to raise_error(ArgumentError, /Image validation failed/)
      end

      it "skips validation when requested" do
        result = described_class.to_mcp_image_content(
          "invalid data",
          validate: false,
          mime_type: "image/jpeg"
        )
        expect(result[:type]).to eq("image")
        expect(result[:mimeType]).to eq("image/jpeg")
      end
    end

    context "with base64 encoded data" do
      it "handles pre-encoded base64 data" do
        result = described_class.to_mcp_image_content(encoded_jpeg)

        expect(result[:type]).to eq("image")
        expect(result[:data]).to eq(encoded_jpeg)
        expect(result[:mimeType]).to eq("image/jpeg")
      end

      it "validates decoded data" do
        invalid_base64 = described_class.encode_base64("not image data")
        expect do
          described_class.to_mcp_image_content(invalid_base64)
        end.to raise_error(ArgumentError, /Image validation failed/)
      end
    end

    context "with explicit MIME type" do
      it "uses provided MIME type" do
        result = described_class.to_mcp_image_content(
          jpeg_data,
          mime_type: "image/custom",
          validate: false
        )
        expect(result[:mimeType]).to eq("image/custom")
      end
    end

    context "with custom validation settings" do
      let(:large_image) { jpeg_data + ("x" * 1000) }

      it "respects max_size parameter" do
        expect do
          described_class.to_mcp_image_content(large_image, max_size: 100)
        end.to raise_error(ArgumentError, /exceeds maximum allowed size/)
      end
    end
  end

  describe ".file_to_mcp_image_content" do
    let(:temp_file) { Tempfile.new(["test_image", ".jpg"]) }
    let(:jpeg_data) { "#{[0xFF, 0xD8, 0xFF, 0xE0].pack("C*")}jpeg content" }

    before do
      temp_file.binmode
      temp_file.write(jpeg_data)
      temp_file.close
    end

    after do
      temp_file.unlink
    end

    it "converts image file to MCP format" do
      result = described_class.file_to_mcp_image_content(temp_file.path)

      expect(result[:type]).to eq("image")
      expect(result[:mimeType]).to eq("image/jpeg")
      expect(result[:data]).to be_a(String)
    end

    it "raises error for non-existent file" do
      expect do
        described_class.file_to_mcp_image_content("/non/existent/file.jpg")
      end.to raise_error(ArgumentError, /Image file not found/)
    end

    context "with unreadable file" do
      before do
        allow(File).to receive(:exist?).with(temp_file.path).and_return(true)
        allow(File).to receive(:readable?).with(temp_file.path).and_return(false)
      end

      it "raises error for unreadable file" do
        expect do
          described_class.file_to_mcp_image_content(temp_file.path)
        end.to raise_error(ArgumentError, /Image file not readable/)
      end
    end

    it "handles edge cases in file operations" do
      temp_dir = Dir.mktmpdir
      non_image_file = File.join(temp_dir, "text.txt")
      File.write(non_image_file, "This is just text")

      # Should detect that this isn't an image and handle gracefully
      expect do
        described_class.file_to_mcp_image_content(non_image_file)
      end.to raise_error(ArgumentError, /Image validation failed.*Unrecognized or invalid image format/)

      FileUtils.rm_rf(temp_dir)
    end
  end

  describe ".extract_metadata" do
    let(:jpeg_data) { "#{[0xFF, 0xD8, 0xFF, 0xE0].pack("C*")}jpeg content" }

    it "extracts basic metadata" do
      metadata = described_class.extract_metadata(jpeg_data)

      expect(metadata[:size]).to eq(jpeg_data.bytesize)
      expect(metadata[:mime_type]).to eq("image/jpeg")
      expect(metadata[:format]).to eq("JPEG")
    end

    it "handles empty data gracefully" do
      expect(described_class.extract_metadata("")).to eq({})
      expect(described_class.extract_metadata(nil)).to eq({})
    end

    it "handles unknown formats" do
      metadata = described_class.extract_metadata("unknown data")
      expect(metadata[:size]).to eq("unknown data".bytesize)
      expect(metadata[:mime_type]).to be_nil
      expect(metadata[:format]).to be_nil
    end
  end

  describe "dimension extraction" do
    context "with PNG data" do
      # Simple PNG with 100x200 dimensions
      let(:png_with_dimensions) do
        signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A].pack("C*")
        ihdr_length = [13].pack("N")
        ihdr_type = "IHDR"
        width = [100].pack("N")
        height = [200].pack("N")
        rest = "rest of header"

        signature + ihdr_length + ihdr_type + width + height + rest
      end

      it "extracts PNG dimensions" do
        metadata = described_class.extract_metadata(png_with_dimensions)
        expect(metadata[:width]).to eq(100)
        expect(metadata[:height]).to eq(200)
      end
    end

    context "with GIF data" do
      # Simple GIF with 150x100 dimensions (little-endian)
      let(:gif_with_dimensions) do
        signature = "GIF89a"
        width = [150].pack("v")    # Little-endian 16-bit
        height = [100].pack("v")   # Little-endian 16-bit
        rest = "rest of gif data"

        signature + width + height + rest
      end

      it "extracts GIF dimensions" do
        metadata = described_class.extract_metadata(gif_with_dimensions)
        expect(metadata[:width]).to eq(150)
        expect(metadata[:height]).to eq(100)
      end
    end

    context "with incomplete image data" do
      it "handles incomplete data gracefully" do
        short_png = [0x89, 0x50, 0x4E, 0x47].pack("C*")
        metadata = described_class.extract_metadata(short_png)
        expect(metadata[:width]).to be_nil
        expect(metadata[:height]).to be_nil
      end
    end
  end

  describe "integration scenarios" do
    let(:sample_jpeg) { "#{[0xFF, 0xD8, 0xFF, 0xE0].pack("C*")}sample jpeg data" }

    it "handles full workflow: detect -> validate -> convert" do
      # 1. Detection
      format = described_class.detect_image_format(sample_jpeg)
      expect(format).to eq("image/jpeg")

      # 2. Validation
      validation = described_class.validate_image(sample_jpeg)
      expect(validation[:valid]).to be true

      # 3. Conversion
      content = described_class.to_mcp_image_content(sample_jpeg)
      expect(content[:type]).to eq("image")
      expect(content[:mimeType]).to eq("image/jpeg")

      # 4. Round-trip decode
      decoded = described_class.decode_base64(content[:data])
      expect(decoded).to eq(sample_jpeg)
    end

    it "handles edge cases in file operations" do
      temp_dir = Dir.mktmpdir
      non_image_file = File.join(temp_dir, "text.txt")
      File.write(non_image_file, "This is just text")

      # Should detect that this isn't an image and handle gracefully
      expect do
        described_class.file_to_mcp_image_content(non_image_file)
      end.to raise_error(ArgumentError, /Image validation failed.*Unrecognized or invalid image format/)

      FileUtils.rm_rf(temp_dir)
    end
  end
end
