# frozen_string_literal: true

require "fileutils"
require "date"

module VectorMCP
  module Logging
    module Outputs
      class File < Base
        def initialize(config = {})
          super
          @path = @config[:path] or raise OutputError, "File path required"
          @max_size = parse_size(@config[:max_size] || "100MB")
          @max_files = @config[:max_files] || 7
          @rotation = @config[:rotation] || "daily"
          @mutex = Mutex.new
          @file = nil
          @current_date = nil

          ensure_directory_exists
          open_file
        end

        def close
          @mutex.synchronize do
            @file&.close
            @file = nil
          end
          super
        end

        protected

        def write_formatted(message)
          @mutex.synchronize do
            rotate_if_needed
            @file.write(message)
            @file.flush
          end
        end

        private

        def ensure_directory_exists
          dir = ::File.dirname(@path)
          FileUtils.mkdir_p(dir) unless ::File.directory?(dir)
        rescue StandardError => e
          raise OutputError, "Cannot create log directory #{dir}: #{e.message}"
        end

        def open_file
          @file = ::File.open(current_log_path, "a")
          @file.sync = true
          @current_date = Date.today if daily_rotation?
        rescue StandardError => e
          raise OutputError, "Cannot open log file #{current_log_path}: #{e.message}"
        end

        def current_log_path
          if daily_rotation?
            base, ext = split_path(@path)
            "#{base}_#{Date.today.strftime("%Y%m%d")}#{ext}"
          else
            @path
          end
        end

        def rotate_if_needed
          return unless should_rotate?

          rotate_file
          open_file
        end

        def should_rotate?
          return false unless @file

          case @rotation
          when "daily"
            daily_rotation? && @current_date != Date.today
          when "size"
            @file.size >= @max_size
          else
            false
          end
        end

        def rotate_file
          @file&.close

          if daily_rotation?
            cleanup_old_files
          else
            rotate_numbered_files
          end
        end

        def daily_rotation?
          @rotation == "daily"
        end

        def rotate_numbered_files
          return unless ::File.exist?(@path)

          (@max_files - 1).downto(1) do |i|
            old_file = "#{@path}.#{i}"
            new_file = "#{@path}.#{i + 1}"

            ::File.rename(old_file, new_file) if ::File.exist?(old_file)
          end

          ::File.rename(@path, "#{@path}.1")
        end

        def cleanup_old_files
          base, ext = split_path(@path)
          pattern = "#{base}_*#{ext}"

          old_files = Dir.glob(pattern).reverse
          files_to_remove = old_files[@max_files..] || []

          files_to_remove.each do |file|
            ::File.unlink(file)
          rescue StandardError => e
            fallback_write("Warning: Could not remove old log file #{file}: #{e.message}\n")
          end
        end

        def split_path(path)
          ext = ::File.extname(path)
          base = path.chomp(ext)
          [base, ext]
        end

        def parse_size(size_str)
          size_str = size_str.to_s.upcase

          raise OutputError, "Invalid size format: #{size_str}" unless size_str =~ /\A(\d+)(KB|MB|GB)?\z/

          number = ::Regexp.last_match(1).to_i
          unit = ::Regexp.last_match(2) || "B"

          case unit
          when "KB"
            number * 1024
          when "MB"
            number * 1024 * 1024
          when "GB"
            number * 1024 * 1024 * 1024
          else
            number
          end
        end
      end
    end
  end
end
