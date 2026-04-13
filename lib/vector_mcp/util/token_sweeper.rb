# frozen_string_literal: true

module VectorMCP
  module Util
    # Stateless recursive traversal utility for parsed JSON-like structures.
    #
    # {.sweep} walks Hashes, Arrays, and String leaves, yielding each String
    # value together with its parent Hash key (or the enclosing Hash key of
    # the nearest containing Array). The block's return value replaces the
    # String in the output. All other scalar types (Integer, Float, nil,
    # Boolean, etc.) are returned unchanged and are not yielded.
    #
    # The method is purely functional: it never mutates the input structure
    # and always returns a fresh Hash/Array spine when containers are
    # encountered. Circular references are detected via an identity-compared
    # visited set and the originally-referenced node is returned unchanged
    # on cycles.
    module TokenSweeper
      # Traverse +obj+ and return a new structure with String leaves
      # transformed by +block+.
      #
      # @param obj [Object] the object to sweep (typically Hash/Array/String/scalar).
      # @yield [value, parent_key] invoked for each String leaf.
      # @yieldparam value [String] the String value.
      # @yieldparam parent_key [Object, nil] the Hash key under which +value+
      #   lives, or +nil+ when the String is a top-level scalar; propagated
      #   from the nearest containing Hash when inside Arrays.
      # @yieldreturn [Object] the replacement value.
      # @return [Object] the transformed structure.
      def self.sweep(obj, &block)
        raise ArgumentError, "TokenSweeper.sweep requires a block" unless block

        walk(obj, nil, {}.compare_by_identity, &block)
      end

      class << self
        private

        def walk(obj, parent_key, visited, &)
          case obj
          when Hash  then walk_hash(obj, visited, &)
          when Array then walk_array(obj, parent_key, visited, &)
          when String then yield(obj, parent_key)
          else obj
          end
        end

        def walk_hash(hash, visited, &)
          return hash if visited[hash]

          visited[hash] = true
          begin
            hash.each_with_object({}) do |(key, value), out|
              out[key] = walk(value, key, visited, &)
            end
          ensure
            visited.delete(hash)
          end
        end

        def walk_array(array, parent_key, visited, &)
          return array if visited[array]

          visited[array] = true
          begin
            array.map { |element| walk(element, parent_key, visited, &) }
          ensure
            visited.delete(array)
          end
        end
      end
    end
  end
end
