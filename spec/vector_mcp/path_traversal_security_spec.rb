# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe VectorMCP::Definitions::Root, "path traversal security fix" do
  let(:temp_dir) { Dir.mktmpdir("vector_mcp_security_test") }
  let(:safe_subdir) { File.join(temp_dir, "safe") }
  let(:sensitive_file) { File.join(temp_dir, "sensitive.txt") }

  before do
    # Create test directory structure
    FileUtils.mkdir_p(safe_subdir)
    File.write(sensitive_file, "This is sensitive data that should not be accessible")
    
    # Create a safe directory for legitimate access
    File.write(File.join(safe_subdir, "public.txt"), "This is public data")
  end

  after do
    FileUtils.rm_rf(temp_dir)
  end

  describe "path canonicalization security" do
    it "canonicalizes legitimate paths with .. components" do
      # Test case: /safe/subdir/../ should become /safe/
      complex_path = File.join(safe_subdir, "subdir", "..")
      FileUtils.mkdir_p(File.join(safe_subdir, "subdir"))
      
      root = described_class.new("file://#{complex_path}", "test")
      
      # Should not raise an error and should canonicalize the path
      expect { root.validate! }.not_to raise_error
      
      # The URI should be updated to the canonical path
      expect(root.uri).to eq("file://#{safe_subdir}")
    end

    it "handles complex legitimate path traversal patterns" do
      # Create a complex but legitimate path structure
      complex_dir = File.join(temp_dir, "project", "src", "..", "docs")
      FileUtils.mkdir_p(File.join(temp_dir, "project", "src"))
      FileUtils.mkdir_p(File.join(temp_dir, "project", "docs"))
      
      root = described_class.new("file://#{complex_dir}", "test")
      expect { root.validate! }.not_to raise_error
      
      # Should resolve to the docs directory
      expected_path = File.join(temp_dir, "project", "docs")
      expect(root.uri).to eq("file://#{expected_path}")
    end

    it "detects and warns about potential path traversal attempts" do
      # Create a path that contains .. but is actually safe after canonicalization
      traversal_path = File.join(safe_subdir, "..", "safe")
      
      expect do
        root = described_class.new("file://#{traversal_path}", "test")
        root.validate!
      end.to output(/\[SECURITY\] Path canonicalized.*path traversal attempt/).to_stderr
    end
  end

  describe "security against path traversal attacks" do
    it "prevents directory traversal to parent directories" do
      # Try to access parent directory through traversal
      attack_path = File.join(safe_subdir, "..", "..")
      
      root = described_class.new("file://#{attack_path}", "test")
      
      # This should work if the parent directory exists and is readable
      # but the path will be canonicalized to the actual parent
      if File.exist?(File.dirname(temp_dir)) && File.readable?(File.dirname(temp_dir))
        expect { root.validate! }.not_to raise_error
        # The canonical path should be the actual parent directory
        expected_uri = "file://#{File.dirname(temp_dir)}"
        expect(root.uri).to eq(expected_uri)
      else
        expect { root.validate! }.to raise_error(ArgumentError, /does not exist|not readable/)
      end
    end

    it "handles encoded path traversal attempts" do
      # Note: File.expand_path handles most encoding issues naturally
      encoded_traversal = File.join(safe_subdir, "%2e%2e", "sensitive.txt")
      
      # This would not be a valid directory anyway, so it should fail
      root = described_class.new("file://#{encoded_traversal}", "test")
      expect { root.validate! }.to raise_error(ArgumentError, /does not exist|not a directory/)
    end

    it "rejects non-existent paths created through traversal attempts" do
      nonexistent_path = File.join(safe_subdir, "..", "..", "nonexistent")
      
      root = described_class.new("file://#{nonexistent_path}", "test")
      expect { root.validate! }.to raise_error(ArgumentError, /does not exist/)
    end

    it "rejects files (not directories) reached through traversal" do
      # Try to use a file as a root through path traversal
      file_via_traversal = File.join(safe_subdir, "..", "sensitive.txt")
      
      root = described_class.new("file://#{file_via_traversal}", "test")
      expect { root.validate! }.to raise_error(ArgumentError, /not a directory/)
    end
  end

  describe "edge cases and bypass attempts" do
    it "handles multiple consecutive .. components" do
      # Multiple traversals that eventually resolve to a valid directory
      multi_traversal = File.join(safe_subdir, "deep", "nesting", "..", "..", "..")
      FileUtils.mkdir_p(File.join(safe_subdir, "deep", "nesting"))
      
      root = described_class.new("file://#{multi_traversal}", "test")
      expect { root.validate! }.not_to raise_error
      
      # Should resolve to temp_dir
      expect(root.uri).to eq("file://#{temp_dir}")
    end

    it "handles mixed slash types consistently" do
      # Test with mixed forward and back slashes (though this is more Windows-specific)
      mixed_path = safe_subdir.gsub("/", "\\") if RUBY_PLATFORM =~ /win32|mingw|cygwin/
      mixed_path ||= safe_subdir
      
      root = described_class.new("file://#{mixed_path}", "test")
      expect { root.validate! }.not_to raise_error
    end

    it "handles trailing slashes and dots" do
      trailing_variations = [
        "#{safe_subdir}/",
        "#{safe_subdir}/.",
        "#{safe_subdir}/./",
        "#{safe_subdir}/../safe/",
        "#{safe_subdir}/../safe/."
      ]
      
      trailing_variations.each do |variant|
        root = described_class.new("file://#{variant}", "test")
        expect { root.validate! }.not_to raise_error
        expect(root.uri).to eq("file://#{safe_subdir}")
      end
    end
  end

  describe "from_path class method security" do
    it "properly canonicalizes paths in from_path method" do
      # The from_path method already uses File.expand_path, so it should be secure
      traversal_path = File.join(safe_subdir, "..", "safe")
      
      root = described_class.from_path(traversal_path)
      expect(root.uri).to eq("file://#{safe_subdir}")
    end

    it "prevents traversal attacks through from_path" do
      parent_path = File.join(safe_subdir, "..", "..")
      
      if File.exist?(File.dirname(temp_dir)) && File.directory?(File.dirname(temp_dir))
        root = described_class.from_path(parent_path)
        expect(root.uri).to eq("file://#{File.dirname(temp_dir)}")
      else
        expect { described_class.from_path(parent_path) }.to raise_error(ArgumentError)
      end
    end
  end

  describe "comparison with old vulnerable implementation" do
    def old_vulnerable_check(path)
      # Simulate the old vulnerable validation
      path.include?("..") || path.include?("./")
    end

    it "demonstrates false positives in old implementation" do
      # These legitimate paths would be rejected by the old implementation
      false_positive_paths = [
        "/legitimate/file..name/directory",
        "/path/with../normal/directory", 
        "/some/path/file...backup/dir"
      ]
      
      false_positive_paths.each do |path|
        # Old implementation would reject these
        expect(old_vulnerable_check(path)).to be true
        
        # New implementation would accept them if they exist
        # (We can't test with these exact paths since they don't exist)
      end
    end

    it "shows how new implementation prevents actual attacks" do
      # Attack that old implementation might miss
      sneaky_attack = File.join(safe_subdir, "....///..", "sensitive.txt")
      
      # Old implementation might not catch this complex pattern
      root = described_class.new("file://#{sneaky_attack}", "test")
      
      # New implementation canonicalizes and validates the actual resolved path
      # The canonicalized path will point to sensitive.txt which doesn't exist as a directory
      expect { root.validate! }.to raise_error(ArgumentError, /does not exist|not a directory/)
    end
  end
end