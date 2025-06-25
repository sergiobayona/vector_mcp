# frozen_string_literal: true

require "yaml"

module VectorMCP
  module Logging
    class Configuration
      DEFAULT_CONFIG = {
        level: "INFO",
        format: "text",
        output: "console",
        components: {},
        console: {
          colorize: true,
          include_timestamp: true,
          include_thread: false
        },
        file: {
          path: nil,
          rotation: "daily",
          max_size: "100MB",
          max_files: 7
        }
      }.freeze

      attr_reader :config

      def initialize(config = {})
        @config = deep_merge(DEFAULT_CONFIG, normalize_config(config))
        validate_config!
      end

      def self.from_file(path)
        config = YAML.load_file(path)
        new(config["logging"] || config)
      rescue StandardError => e
        raise ConfigurationError, "Failed to load configuration from #{path}: #{e.message}"
      end

      def self.from_env
        config = {}

        config[:level] = ENV["VECTORMCP_LOG_LEVEL"] if ENV["VECTORMCP_LOG_LEVEL"]
        config[:format] = ENV["VECTORMCP_LOG_FORMAT"] if ENV["VECTORMCP_LOG_FORMAT"]
        config[:output] = ENV["VECTORMCP_LOG_OUTPUT"] if ENV["VECTORMCP_LOG_OUTPUT"]

        config[:file] = { path: ENV["VECTORMCP_LOG_FILE_PATH"] } if ENV["VECTORMCP_LOG_FILE_PATH"]

        new(config)
      end

      def level_for(component)
        component_level = @config[:components][component.to_s]
        level_value = component_level || @config[:level]
        Logging.level_value(level_value)
      end

      def set_component_level(component, level)
        @config[:components][component.to_s] = if level.is_a?(Integer)
                                                 Logging.level_name(level)
                                               else
                                                 level.to_s.upcase
                                               end
      end

      def component_config(component_name)
        @config[:components][component_name.to_s] || {}
      end

      def console_config
        @config[:console]
      end

      def file_config
        @config[:file]
      end

      def format
        @config[:format]
      end

      def output
        @config[:output]
      end

      def configure(&)
        instance_eval(&) if block_given?
        validate_config!
      end

      def level(new_level)
        @config[:level] = new_level.to_s.upcase
      end

      def component(name, level:)
        @config[:components][name.to_s] = level.to_s.upcase
      end

      def console(options = {})
        @config[:console].merge!(options)
      end

      def file(options = {})
        @config[:file].merge!(options)
      end

      def to_h
        @config.dup
      end

      private

      def normalize_config(config)
        case config
        when Hash
          config.transform_keys(&:to_sym)
        when String
          { level: config }
        else
          {}
        end
      end

      def deep_merge(hash1, hash2)
        result = hash1.dup
        hash2.each do |key, value|
          result[key] = if result[key].is_a?(Hash) && value.is_a?(Hash)
                          deep_merge(result[key], value)
                        else
                          value
                        end
        end
        result
      end

      def validate_config!
        validate_level!(@config[:level])
        @config[:components].each_value do |level|
          validate_level!(level)
        end

        raise ConfigurationError, "Invalid format: #{@config[:format]}" unless %w[text json].include?(@config[:format])

        return if %w[console file both].include?(@config[:output])

        raise ConfigurationError, "Invalid output: #{@config[:output]}"
      end

      def validate_level!(level)
        return if Logging::LEVELS.key?(level.to_s.upcase.to_sym)

        raise ConfigurationError, "Invalid log level: #{level}"
      end
    end
  end
end
