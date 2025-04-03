# frozen_string_literal: true

require 'json'
require 'base64'

module MCPRuby
  module Util
    module_function

    # Helper to convert tool/resource results into MCP 'content' array
    def convert_to_mcp_content(result)
      items = result.is_a?(Array) ? result : [result]

      items.map do |item|
        case item
        when String
          { type: 'text', text: item }
        when Hash
          # Could be a pre-formatted content object, or just data to JSONify
          if item.key?(:type) && %w[text image resource blob].include?(item[:type].to_s)
            # Maybe add symbol key conversion here if needed
            item
          else
            { type: 'text', text: item.to_json, mimeType: 'application/json' }
          end
        when ->(obj) { obj.respond_to?(:force_encoding) && obj.encoding == Encoding::ASCII_8BIT }
          { type: 'blob', blob: Base64.strict_encode64(item), mimeType: 'application/octet-stream' }
        # Add specific class handling (e.g., for custom Image classes) if needed
        # when SomeImageClass
        #   content_array << { type: 'image', data: Base64.strict_encode64(item.data), mimeType: item.mime_type }
        else
          { type: 'text', text: item.to_s }
        end
      end
    end

    # Basic helper to try and get ID from malformed JSON for error reporting
    def extract_id_from_invalid_json(line)
      # Improved regex to handle strings and numbers more reliably
      match = line.match(/"id"\s*:\s* (?: "((?:[^"\\]|\\.)*)" | (\d+) ) /x)
      #                  |     |      |   |  1: Str Content | | 2: Num| |
      #                  |     |      |   -------------------   -------
      #                  |     |      ---------------------------------
      #                  |     -----------------------------------------
      #                  -----------------------------------------------
      match ? (match[1] || match[2].to_i) : nil # Return string content or integer
    end
  end
end
