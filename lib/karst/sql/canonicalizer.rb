# frozen_string_literal: true

module Karst
  module Sql
    # Produces a conservative structural representation of SQL without parsing it.
    # The scanner is intentionally kept together so its state transitions remain auditable.
    # rubocop:disable Metrics/ClassLength
    class Canonicalizer
      class << self
        def call(sql)
          raise ArgumentError, "sql must be a String" unless sql.is_a?(String)

          canonical = scan(sql)
          canonical&.strip&.freeze
        end

        private

        # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
        def scan(sql)
          output = +""
          index = 0
          space_pending = false

          while index < sql.length
            character = sql[index]

            if whitespace?(character)
              space_pending = true
              index += 1
            elsif sql[index, 2] == "--"
              index = skip_line_comment(sql, index + 2)
              space_pending = true
            elsif sql[index, 2] == "/*"
              ending = block_comment_end(sql, index)
              return unless ending

              comment = sql[index...ending]
              if semantic_comment?(comment)
                prefix = comment[0, 3]
                original_body = comment[3...-2]
                leading_space = " " if original_body.match?(/\A\s/)
                trailing_space = " " if original_body.match?(/\s\z/)
                body = scan(original_body)
                return unless body

                body = body.strip
                append(output, "#{prefix}#{leading_space}#{body}#{trailing_space}*/", space_pending)
                space_pending = false
              else
                space_pending = true
              end
              index = ending
            elsif character == "'"
              ending = quoted_end(sql, index, "'", backslash_escape: true)
              return unless ending
              return if sql[index...ending].include?("\\")

              append(output, "?", space_pending)
              space_pending = false
              index = ending
            elsif ['"', "`"].include?(character)
              ending = quoted_end(sql, index, character, backslash_escape: character == "`")
              return unless ending

              append(output, sql[index...ending], space_pending)
              space_pending = false
              index = ending
            elsif (delimiter = dollar_quote_delimiter(sql, index))
              ending = sql.index(delimiter, index + delimiter.length)
              return unless ending

              append(output, "?", space_pending)
              space_pending = false
              index = ending + delimiter.length
            elsif boolean_at?(sql, index)
              length = sql[index, 4].casecmp?("true") ? 4 : 5
              append(output, "?", space_pending)
              space_pending = false
              index += length
            elsif (length = numeric_length(sql, index))
              append(output, "?", space_pending)
              space_pending = false
              index += length
            elsif character == "\\"
              return
            else
              append(output, character, space_pending)
              space_pending = false
              index += 1
            end
          end

          output
        end
        # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

        def append(output, value, space_pending)
          output << " " if space_pending && !output.empty?
          output << value
        end

        def whitespace?(character)
          character.match?(/\s/)
        end

        def skip_line_comment(sql, index)
          newline = sql.index(/[\r\n]/, index)
          newline || sql.length
        end

        # Optimizer hints and MySQL executable comments can affect execution, so retain them.
        def semantic_comment?(comment)
          comment.start_with?("/*+", "/*!")
        end

        # rubocop:disable Metrics/MethodLength
        def block_comment_end(sql, start)
          depth = 1
          index = start + 2
          while index < sql.length
            if sql[index, 2] == "/*"
              depth += 1
              index += 2
            elsif sql[index, 2] == "*/"
              depth -= 1
              return index + 2 if depth.zero?

              index += 2
            else
              index += 1
            end
          end
          nil
        end
        # rubocop:enable Metrics/MethodLength

        def dollar_quote_delimiter(sql, index)
          /\A\$(?:[A-Za-z_][A-Za-z0-9_]*)?\$/.match(sql[index..])&.[](0)
        end

        # rubocop:disable Metrics/MethodLength
        def quoted_end(sql, start, quote, backslash_escape: false)
          index = start + 1
          while index < sql.length
            if backslash_escape && sql[index] == "\\"
              index += 2
            elsif sql[index] == quote
              return index + 1 unless sql[index + 1] == quote

              index += 2
            else
              index += 1
            end
          end
          nil
        end
        # rubocop:enable Metrics/MethodLength

        def boolean_at?(sql, index)
          word = if sql[index, 4]&.casecmp?("true")
                   sql[index, 4]
                 elsif sql[index, 5]&.casecmp?("false")
                   sql[index, 5]
                 end
          return false unless word

          token_boundary?(previous_character(sql, index)) && token_boundary?(sql[index + word.length])
        end

        def numeric_length(sql, index)
          match = /\A[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?/.match(sql[index..])
          return unless match
          return if sign_is_binary?(sql, index, match[0])
          return unless token_boundary?(previous_character(sql, index)) && token_boundary?(sql[index + match[0].length])

          match[0].length
        end

        def sign_is_binary?(sql, index, number)
          return false unless number.start_with?("+", "-")

          previous = index - 1
          previous -= 1 while previous >= 0 && whitespace?(sql[previous])
          return false if preceding_word(sql, previous).casecmp?("SELECT")

          previous >= 0 && !"(,=<>+-*/%".include?(sql[previous])
        end

        def preceding_word(sql, ending)
          return "" if ending.negative?

          start = ending
          start -= 1 while start >= 0 && sql[start].match?(/[A-Za-z]/)
          sql[(start + 1)..ending]
        end

        def token_boundary?(character)
          character.nil? || !character.match?(/[[:alnum:]_$]/)
        end

        def previous_character(sql, index)
          index.zero? ? nil : sql[index - 1]
        end
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
