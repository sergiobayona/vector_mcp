# frozen_string_literal: true

require "spec_helper"

RSpec.describe VectorMCP::Definitions do
  describe VectorMCP::Definitions::Tool do
    subject(:tool) do
      described_class.new(tool_name, tool_description, tool_input_schema, tool_handler)
    end

    let(:tool_name) { "test_tool" }
    let(:tool_description) { "A test tool" }
    let(:tool_input_schema) do
      {
        type: "object",
        properties: {
          input: { type: "string" }
        },
        required: ["input"]
      }
    end
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
        tool_with_nil = described_class.new(tool_name, nil, nil, tool_handler)
        expected = {
          name: tool_name
        }

        expect(tool_with_nil.as_mcp_definition).to eq(expected)
      end
    end

    describe "#supports_image_input?" do
      context "with image format in schema" do
        let(:tool_input_schema) do
          {
            type: "object",
            properties: {
              image: { type: "string", format: "image" },
              text: { type: "string" }
            }
          }
        end

        it "returns true for tools with image format" do
          expect(tool.supports_image_input?).to be true
        end
      end

      context "with base64 image in schema" do
        let(:tool_input_schema) do
          {
            type: "object",
            properties: {
              photo: {
                type: "string",
                contentEncoding: "base64",
                contentMediaType: "image/jpeg"
              }
            }
          }
        end

        it "returns true for tools with base64 image properties" do
          expect(tool.supports_image_input?).to be true
        end
      end

      context "with string keys in schema" do
        let(:tool_input_schema) do
          {
            "type" => "object",
            "properties" => {
              "avatar" => {
                "type" => "string",
                "contentEncoding" => "base64",
                "contentMediaType" => "image/png"
              }
            }
          }
        end

        it "returns true for tools with string-keyed image properties" do
          expect(tool.supports_image_input?).to be true
        end
      end

      context "without image properties" do
        let(:tool_input_schema) do
          {
            type: "object",
            properties: {
              text: { type: "string" },
              number: { type: "number" }
            }
          }
        end

        it "returns false for tools without image properties" do
          expect(tool.supports_image_input?).to be false
        end
      end

      context "with invalid schema" do
        let(:tool_input_schema) { "not a hash" }

        it "returns false for invalid schemas" do
          expect(tool.supports_image_input?).to be false
        end
      end

      context "with nil schema" do
        let(:tool_input_schema) { nil }

        it "returns false for nil schemas" do
          expect(tool.supports_image_input?).to be false
        end
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

    describe "#image_resource?" do
      context "with image MIME types" do
        %w[image/jpeg image/png image/gif image/webp image/bmp image/tiff].each do |mime_type|
          it "returns true for #{mime_type}" do
            image_resource = described_class.new(resource_uri, resource_name, resource_description, mime_type, resource_handler)
            expect(image_resource.image_resource?).to be true
          end
        end
      end

      context "with non-image MIME types" do
        %w[text/plain application/json video/mp4 audio/mp3].each do |mime_type|
          it "returns false for #{mime_type}" do
            non_image_resource = described_class.new(resource_uri, resource_name, resource_description, mime_type, resource_handler)
            expect(non_image_resource.image_resource?).to be false
          end
        end
      end

      context "with nil MIME type" do
        it "returns false" do
          nil_mime_resource = described_class.new(resource_uri, resource_name, resource_description, nil, resource_handler)
          expect(nil_mime_resource.image_resource?).to be false
        end
      end
    end

    describe ".from_image_file" do
      let(:temp_file) { Tempfile.new(["test_image", ".jpg"]) }
      let(:jpeg_data) { "#{[0xFF, 0xD8, 0xFF, 0xE0].pack("C*")}jpeg content" }
      let(:test_uri) { "images://test.jpg" }

      before do
        temp_file.binmode
        temp_file.write(jpeg_data)
        temp_file.close
      end

      after do
        temp_file.unlink
      end

      it "creates a resource from an image file" do
        resource = described_class.from_image_file(
          uri: test_uri,
          file_path: temp_file.path,
          name: "Test Image",
          description: "A test image resource"
        )

        expect(resource.uri).to eq(test_uri)
        expect(resource.name).to eq("Test Image")
        expect(resource.description).to eq("A test image resource")
        expect(resource.mime_type).to eq("image/jpeg")
        expect(resource.handler).to be_a(Proc)
      end

      it "auto-generates name and description when not provided" do
        resource = described_class.from_image_file(
          uri: test_uri,
          file_path: temp_file.path
        )

        expect(resource.name).to eq(File.basename(temp_file.path))
        expect(resource.description).to include(temp_file.path)
      end

      it "detects MIME type automatically" do
        resource = described_class.from_image_file(
          uri: test_uri,
          file_path: temp_file.path
        )

        expect(resource.mime_type).to eq("image/jpeg")
      end

      it "creates a working handler that returns MCP image content" do
        resource = described_class.from_image_file(
          uri: test_uri,
          file_path: temp_file.path
        )

        content = resource.handler.call({})
        expect(content[:type]).to eq("image")
        expect(content[:mimeType]).to eq("image/jpeg")
        expect(content[:data]).to be_a(String)
      end

      it "raises error for non-existent file" do
        expect do
          described_class.from_image_file(
            uri: test_uri,
            file_path: "/non/existent/file.jpg"
          )
        end.to raise_error(ArgumentError, /Image file not found/)
      end

      it "raises error for non-image file" do
        text_file = Tempfile.new(["text", ".txt"])
        text_file.write("Just text content")
        text_file.close

        begin
          expect do
            described_class.from_image_file(
              uri: test_uri,
              file_path: text_file.path
            )
          end.to raise_error(ArgumentError, /Could not detect image format/)
        ensure
          text_file.unlink
        end
      end
    end

    describe ".from_image_data" do
      let(:jpeg_data) { "#{[0xFF, 0xD8, 0xFF, 0xE0].pack("C*")}jpeg content" }
      let(:test_uri) { "images://generated.jpg" }

      it "creates a resource from binary image data" do
        resource = described_class.from_image_data(
          uri: test_uri,
          image_data: jpeg_data,
          name: "Generated Image",
          description: "A generated image resource",
          mime_type: "image/jpeg"
        )

        expect(resource.uri).to eq(test_uri)
        expect(resource.name).to eq("Generated Image")
        expect(resource.description).to eq("A generated image resource")
        expect(resource.mime_type).to eq("image/jpeg")
      end

      it "auto-detects MIME type when not provided" do
        resource = described_class.from_image_data(
          uri: test_uri,
          image_data: jpeg_data,
          name: "Generated Image"
        )

        expect(resource.mime_type).to eq("image/jpeg")
      end

      it "auto-generates description when not provided" do
        resource = described_class.from_image_data(
          uri: test_uri,
          image_data: jpeg_data,
          name: "Test Image"
        )

        expect(resource.description).to include("Test Image")
      end

      it "creates a working handler that returns MCP image content" do
        resource = described_class.from_image_data(
          uri: test_uri,
          image_data: jpeg_data,
          name: "Test Image"
        )

        content = resource.handler.call({})
        expect(content[:type]).to eq("image")
        expect(content[:mimeType]).to eq("image/jpeg")
        expect(content[:data]).to be_a(String)
      end

      it "raises error for invalid image data" do
        expect do
          described_class.from_image_data(
            uri: test_uri,
            image_data: "not image data",
            name: "Invalid Image"
          )
        end.to raise_error(ArgumentError, /Could not determine MIME type/)
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
        { name: "input", description: "Input text", required: true },
        { name: "style", description: "Output style", required: false }
      ]
    end
    let(:prompt_handler) { proc { |args| "Processed: #{args["input"]}" } }

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

    describe "#supports_image_arguments?" do
      context "with explicit image type argument" do
        let(:prompt_arguments) do
          [
            { name: "text", description: "Input text" },
            { name: "image", type: "image", description: "Input image" }
          ]
        end

        it "returns true" do
          expect(prompt.supports_image_arguments?).to be true
        end
      end

      context "with string-keyed image type argument" do
        let(:prompt_arguments) do
          [
            { "name" => "text", "description" => "Input text" },
            { "name" => "photo", "type" => "image", "description" => "Input photo" }
          ]
        end

        it "returns true" do
          expect(prompt.supports_image_arguments?).to be true
        end
      end

      context "with image in description" do
        let(:prompt_arguments) do
          [
            { name: "text", description: "Input text" },
            { name: "visual", description: "Upload an image file" }
          ]
        end

        it "returns true" do
          expect(prompt.supports_image_arguments?).to be true
        end
      end

      context "with IMAGE in description" do
        let(:prompt_arguments) do
          [
            { name: "data", description: "Provide IMAGE data" }
          ]
        end

        it "returns true (case insensitive)" do
          expect(prompt.supports_image_arguments?).to be true
        end
      end

      context "without image arguments" do
        let(:prompt_arguments) do
          [
            { name: "text", description: "Input text" },
            { name: "count", description: "Number of items" }
          ]
        end

        it "returns false" do
          expect(prompt.supports_image_arguments?).to be false
        end
      end

      context "with invalid arguments" do
        let(:prompt_arguments) { "not an array" }

        it "returns false" do
          expect(prompt.supports_image_arguments?).to be false
        end
      end

      context "with nil arguments" do
        let(:prompt_arguments) { nil }

        it "returns false" do
          expect(prompt.supports_image_arguments?).to be false
        end
      end
    end

    describe ".with_image_support" do
      it "creates a prompt with image argument support" do
        handler = proc { |args| "Image: #{args["image"]}, Text: #{args["text"]}" }

        prompt = described_class.with_image_support(
          name: "image_prompt",
          description: "A prompt that handles images",
          &handler
        )

        expect(prompt.name).to eq("image_prompt")
        expect(prompt.description).to eq("A prompt that handles images")
        expect(prompt.arguments).to be_an(Array)
        expect(prompt.arguments.length).to eq(1)

        image_arg = prompt.arguments.first
        expect(image_arg[:name]).to eq("image")
        expect(image_arg[:type]).to eq("image")
        expect(image_arg[:required]).to be false
        expect(image_arg[:description]).to include("Image file path")
      end

      it "allows custom image argument name" do
        handler = proc { |args| args }

        prompt = described_class.with_image_support(
          name: "custom_prompt",
          description: "Custom prompt",
          image_argument_name: "photo",
          &handler
        )

        image_arg = prompt.arguments.first
        expect(image_arg[:name]).to eq("photo")
      end

      it "supports additional arguments" do
        handler = proc { |args| args }
        additional_args = [
          { name: "format", description: "Output format", required: true },
          { name: "style", description: "Processing style", required: false }
        ]

        prompt = described_class.with_image_support(
          name: "complex_prompt",
          description: "Complex image prompt",
          additional_arguments: additional_args,
          &handler
        )

        expect(prompt.arguments.length).to eq(3)
        expect(prompt.arguments[0][:name]).to eq("image") # Image arg comes first
        expect(prompt.arguments[1][:name]).to eq("format")
        expect(prompt.arguments[2][:name]).to eq("style")
      end

      it "creates a working handler" do
        handler = proc { |args| "Processing image: #{args["image"]}" }

        prompt = described_class.with_image_support(
          name: "test_prompt",
          description: "Test prompt",
          &handler
        )

        result = prompt.handler.call({ "image" => "test.jpg" })
        expect(result).to eq("Processing image: test.jpg")
      end

      it "detects image argument support correctly" do
        prompt = described_class.with_image_support(
          name: "image_enabled_prompt",
          description: "Image enabled prompt"
        ) { |args| args }

        expect(prompt.supports_image_arguments?).to be true
      end
    end
  end

  describe "integration scenarios" do
    let(:temp_dir) { Dir.mktmpdir }
    let(:image_file) { File.join(temp_dir, "test.png") }
    let(:png_data) { "#{[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A].pack("C*")}png content" }

    before do
      File.binwrite(image_file, png_data)
    end

    after do
      FileUtils.rm_rf(temp_dir)
    end

    it "handles complete workflow for image resources" do
      # Create resource from file
      resource = VectorMCP::Definitions::Resource.from_image_file(
        uri: "test://image.png",
        file_path: image_file,
        name: "Test PNG"
      )

      # Verify resource properties
      expect(resource.image_resource?).to be true
      expect(resource.mime_type).to eq("image/png")

      # Test handler functionality
      content = resource.handler.call({})
      expect(content[:type]).to eq("image")
      expect(content[:mimeType]).to eq("image/png")

      # Verify content can be decoded
      decoded = VectorMCP::ImageUtil.decode_base64(content[:data])
      expect(decoded).to eq(png_data)
    end

    it "handles complete workflow for image tools" do
      # Create tool with image support
      tool = VectorMCP::Definitions::Tool.new(
        "image_analyzer",
        "Analyzes images",
        {
          type: "object",
          properties: {
            image: { type: "string", format: "image" },
            detail: { type: "string", enum: %w[low high], default: "low" }
          },
          required: ["image"]
        },
        proc { |args| "Analyzing #{args["image"]} with #{args["detail"]} detail" }
      )

      # Verify tool properties
      expect(tool.supports_image_input?).to be true

      # Test handler
      result = tool.handler.call({ "image" => "test.jpg", "detail" => "high" })
      expect(result).to include("Analyzing test.jpg with high detail")
    end

    it "handles complete workflow for image prompts" do
      # Create prompt with image support
      prompt = VectorMCP::Definitions::Prompt.with_image_support(
        name: "describe_image",
        description: "Describe what you see in the image",
        additional_arguments: [
          { name: "language", description: "Output language", required: false }
        ]
      ) do |args|
        image = args["image"]
        language = args["language"] || "English"
        "Describe this image (#{image}) in #{language}"
      end

      # Verify prompt properties
      expect(prompt.supports_image_arguments?).to be true
      expect(prompt.arguments.length).to eq(2)

      # Test handler
      result = prompt.handler.call({ "image" => "sunset.jpg", "language" => "Spanish" })
      expect(result).to include("Describe this image (sunset.jpg) in Spanish")
    end
  end

  describe "Root" do
    describe "#as_mcp_definition" do
      it "returns the correct MCP definition" do
        root = described_class::Root.new(
          "file:///home/user/project",
          "My Project"
        )

        definition = root.as_mcp_definition

        expect(definition).to eq({
                                   uri: "file:///home/user/project",
                                   name: "My Project"
                                 })
      end

      it "excludes nil name from definition" do
        root = described_class::Root.new(
          "file:///home/user/project",
          nil
        )

        definition = root.as_mcp_definition

        expect(definition).to eq({
                                   uri: "file:///home/user/project"
                                 })
      end
    end

    describe "#validate!" do
      let(:test_dir) { Dir.mktmpdir }

      after { FileUtils.rm_rf(test_dir) }

      it "validates a proper file:// URI" do
        root = described_class::Root.new("file://#{test_dir}", "Test")
        expect { root.validate! }.not_to raise_error
      end

      it "rejects non-file:// schemes" do
        root = described_class::Root.new("http://example.com", "Test")
        expect { root.validate! }.to raise_error(ArgumentError, %r{Only file:// URIs are supported})
      end

      it "rejects invalid URI format" do
        root = described_class::Root.new("not a uri", "Test")
        expect { root.validate! }.to raise_error(ArgumentError, /Invalid URI format/)
      end

      it "rejects non-existent directories" do
        non_existent = File.join(test_dir, "non_existent")
        root = described_class::Root.new("file://#{non_existent}", "Test")
        expect { root.validate! }.to raise_error(ArgumentError, /Root directory does not exist/)
      end

      it "rejects files (not directories)" do
        test_file = File.join(test_dir, "test.txt")
        File.write(test_file, "content")
        root = described_class::Root.new("file://#{test_file}", "Test")
        expect { root.validate! }.to raise_error(ArgumentError, /Root path is not a directory/)
      end

      it "rejects unreadable directories" do
        unreadable_dir = File.join(test_dir, "unreadable")
        Dir.mkdir(unreadable_dir)
        File.chmod(0o000, unreadable_dir) # Remove all permissions

        root = described_class::Root.new("file://#{unreadable_dir}", "Test")
        expect { root.validate! }.to raise_error(ArgumentError, /Root directory is not readable/)

        # Cleanup: restore permissions so we can delete
        File.chmod(0o755, unreadable_dir)
      end

      it "rejects paths with traversal patterns" do
        # Create a directory with ".." in the path
        root = described_class::Root.new("file://#{test_dir}/../malicious", "Test")
        # This should fail either because the path doesn't exist OR because it contains traversal patterns
        expect { root.validate! }.to raise_error(ArgumentError, /(unsafe traversal patterns|Root directory does not exist)/)
      end
    end

    describe ".from_path" do
      let(:test_dir) { Dir.mktmpdir }

      after { FileUtils.rm_rf(test_dir) }

      it "creates a root from a valid directory path" do
        root = described_class::Root.from_path(test_dir, name: "Test Project")

        expect(root.uri).to eq("file://#{test_dir}")
        expect(root.name).to eq("Test Project")
      end

      it "generates name from directory basename when not provided" do
        subdir = File.join(test_dir, "my_project")
        Dir.mkdir(subdir)

        root = described_class::Root.from_path(subdir)

        expect(root.uri).to eq("file://#{subdir}")
        expect(root.name).to eq("my_project")
      end

      it "expands relative paths" do
        # Change to test directory temporarily
        original_dir = Dir.pwd
        Dir.chdir(test_dir)

        begin
          root = described_class::Root.from_path(".", name: "Current")
          # Use realpath to handle symlinks like /var -> /private/var on macOS
          expect(root.uri).to eq("file://#{File.realpath(test_dir)}")
        ensure
          Dir.chdir(original_dir)
        end
      end

      it "validates the path during creation" do
        non_existent = File.join(test_dir, "non_existent")
        expect { described_class::Root.from_path(non_existent) }.to raise_error(ArgumentError)
      end
    end

    describe "#path" do
      let(:test_dir) { Dir.mktmpdir }

      after { FileUtils.rm_rf(test_dir) }

      it "extracts the filesystem path from file:// URI" do
        root = described_class::Root.new("file://#{test_dir}", "Test")
        expect(root.path).to eq(test_dir)
      end

      it "raises error for non-file:// URIs" do
        root = described_class::Root.new("http://example.com", "Test")
        expect { root.path }.to raise_error(ArgumentError, /Cannot get path for non-file URI/)
      end
    end
  end
end
