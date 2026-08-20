# frozen_string_literal: true

require "json"
require_relative "errors"

module Clickwrap
  # Canonical JSON serialization, implementing the JSON Canonicalization Scheme
  # (RFC 8785, https://www.rfc-editor.org/rfc/rfc8785).
  #
  # Receipts are digested and verified by code that may be years newer than the
  # code that wrote them, and by verifiers written in other languages. So the
  # bytes have to be reproducible from the data alone: no Ruby object
  # serialization, no YAML, no hash insertion order, no database column order,
  # no locale-dependent number formatting.
  #
  # The Clickwrap profile adds a few rules on top of RFC 8785, applied by the
  # callers in ReceiptSchema rather than here:
  #
  #   * timestamps are UTC strings with exactly six fractional digits;
  #   * digests are "<algorithm>:<lowercase hex>" strings;
  #   * identifiers are strings, never numbers;
  #   * a value that was never collected is an explicit state object, never
  #     `null` and never a missing key that could mean either; and
  #   * host extensions use keys prefixed `x_`.
  module CanonicalJson
    # Integers above this magnitude cannot survive a round trip through the
    # IEEE 754 double that RFC 8785 assumes, so serializing one would produce
    # bytes another verifier could not reproduce.
    MAX_EXACT_INTEGER = (2**53) - 1

    ESCAPES = {
      "\b" => "\\b",
      "\t" => "\\t",
      "\n" => "\\n",
      "\f" => "\\f",
      "\r" => "\\r",
      '"' => '\\"',
      "\\" => "\\\\"
    }.freeze

    class SerializationError < Clickwrap::Error; end

    class << self
      # Returns the canonical UTF-8 JSON bytes for `value`.
      def generate(value)
        buffer = +""
        write(value, buffer)
        buffer.force_encoding(Encoding::UTF_8)
      end

      alias dump generate

      # Parses JSON text and returns the canonical bytes for it. Useful for
      # verifying a receipt that arrived as arbitrarily formatted JSON.
      def canonicalize(json_text)
        generate(JSON.parse(json_text))
      end

      # True when `json_text` is already in canonical form.
      def canonical?(json_text)
        canonicalize(json_text) == json_text
      rescue JSON::ParserError, SerializationError
        false
      end

      private

      def write(value, buffer)
        case value
        when nil then buffer << "null"
        when true then buffer << "true"
        when false then buffer << "false"
        when String then write_string(value, buffer)
        when Symbol then write_string(value.to_s, buffer)
        when Integer then write_integer(value, buffer)
        when Float then buffer << format_number(value)
        when Array then write_array(value, buffer)
        when Hash then write_object(value, buffer)
        else
          raise SerializationError,
                "#{value.class} cannot appear in canonical JSON. Convert it to a string, " \
                "number, boolean, array, or hash before it reaches a receipt."
        end
      end

      def write_array(array, buffer)
        buffer << "["
        array.each_with_index do |element, index|
          buffer << "," unless index.zero?
          write(element, buffer)
        end
        buffer << "]"
      end

      def write_object(hash, buffer)
        entries = hash.map { |key, value| [canonical_key(key), value] }
        detect_duplicate_keys(entries)

        buffer << "{"
        entries.sort_by { |key, _| utf16_sort_key(key) }.each_with_index do |(key, value), index|
          buffer << "," unless index.zero?
          write_string(key, buffer)
          buffer << ":"
          write(value, buffer)
        end
        buffer << "}"
      end

      def canonical_key(key)
        case key
        when String then key
        when Symbol then key.to_s
        else
          raise SerializationError,
                "Canonical JSON object keys must be strings or symbols, got #{key.class}"
        end
      end

      def detect_duplicate_keys(entries)
        keys = entries.map(&:first)
        return if keys.uniq.length == keys.length

        duplicate = keys.tally.find { |_, count| count > 1 }&.first
        raise SerializationError, "Duplicate object key #{duplicate.inspect} in canonical JSON"
      end

      # RFC 8785 sorts object keys by their UTF-16 code units. Ruby compares
      # strings by UTF-8 bytes, which orders characters outside the Basic
      # Multilingual Plane differently, so encode before comparing.
      def utf16_sort_key(key)
        key.encode(Encoding::UTF_16BE, invalid: :replace, undef: :replace).b
      end

      def write_string(string, buffer)
        # `valid_encoding?` is ALWAYS true on an ASCII-8BIT string — BINARY has
        # no invalid byte sequences by definition — and BINARY is exactly what
        # Rack and CDN headers deliver, so this guard was a no-op for the
        # strings most likely to be malformed. Ten request-evidence columns
        # reach it.
        #
        # Normalizing the tag before validating is safe for every digest ever
        # written: bytes that ARE valid UTF-8 canonicalize byte-identically
        # whether they arrive tagged BINARY or UTF-8 (measured, and pinned by a
        # test below). What changes is only the case that was broken —
        # genuinely invalid bytes used to emit canonical JSON that was itself
        # not valid UTF-8, which RFC 8785 forbids and a verifier in another
        # language may reject or normalize into a different digest. That is the
        # "still verifiable years later" promise failing silently, so it is
        # refused at write time instead.
        utf8 = string.encoding == Encoding::UTF_8 ? string : string.dup.force_encoding(Encoding::UTF_8)
        raise SerializationError, "Canonical JSON strings must be valid UTF-8" unless utf8.valid_encoding?

        buffer << '"'
        utf8.each_char do |char|
          escape = ESCAPES[char]
          buffer << if escape
                      escape
                    elsif char.ord < 0x20
                      format('\\u%04x', char.ord)
                    else
                      char
                    end
        end
        buffer << '"'
      end

      def write_integer(value, buffer)
        if value.abs > MAX_EXACT_INTEGER
          raise SerializationError,
                "#{value} is too large to serialize exactly in canonical JSON. " \
                "Record large identifiers as strings."
        end

        buffer << value.to_s
      end

      # RFC 8785 defers to the ECMAScript Number::toString algorithm, which is
      # not what Ruby's Float#to_s produces: Ruby writes 1.0 where ECMAScript
      # writes 1, and 1.0e-05 where ECMAScript writes 0.00001. This rebuilds
      # the ECMAScript form from Ruby's shortest round-trip digits.
      def format_number(value)
        raise SerializationError, "Canonical JSON cannot represent #{value}" if value.nan? || value.infinite?
        return "0" if value.zero?

        sign = value.negative? ? "-" : ""
        digits, exponent = shortest_digits(value.abs)
        sign + place_decimal_point(digits, exponent)
      end

      # Returns [digits, n] such that the value equals 0.<digits> * 10**n with
      # no leading or trailing zero in `digits`.
      def shortest_digits(magnitude)
        text = magnitude.to_s
        match = /\A(\d+)(?:\.(\d+))?(?:e([+-]?\d+))?\z/.match(text)
        raise SerializationError, "Cannot canonicalize the number #{text}" unless match

        integer_part = match[1]
        fraction_part = match[2] || ""
        exponent = (match[3] || "0").to_i

        digits = integer_part + fraction_part
        position = integer_part.length + exponent

        leading_zeros = digits.length - digits.sub(/\A0+/, "").length
        digits = digits[leading_zeros..] || ""
        position -= leading_zeros

        digits = digits.sub(/0+\z/, "")
        digits = "0" if digits.empty?

        [digits, position]
      end

      def place_decimal_point(digits, position)
        length = digits.length

        if position.between?(length, 21)
          digits + ("0" * (position - length))
        elsif position.positive? && position <= 21
          "#{digits[0, position]}.#{digits[position..]}"
        elsif position > -6 && position <= 0
          "0.#{"0" * -position}#{digits}"
        else
          exponent = position - 1
          exponent_sign = exponent.negative? ? "-" : "+"
          mantissa = length == 1 ? digits : "#{digits[0]}.#{digits[1..]}"
          "#{mantissa}e#{exponent_sign}#{exponent.abs}"
        end
      end
    end
  end
end
