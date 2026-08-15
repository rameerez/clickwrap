# frozen_string_literal: true

require "securerandom"

module Clickwrap
  # Event identifiers.
  #
  # Clickwrap events use ULIDs (https://github.com/ulid/spec): 26 Crockford
  # base32 characters, the first ten encoding milliseconds since the Unix
  # epoch. They sort lexicographically in creation order, which keeps evidence
  # exports and index scans in a sensible sequence, and they carry no host
  # database sequence a reader could use to count unrelated records.
  #
  # The embedded timestamp is a convenience for ordering. It is not the
  # evidentiary time: that is `recorded_at_by_server` on the event, recorded
  # from the application server's clock and described as exactly that.
  module Identifier
    ENCODING = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
    ENCODING_LENGTH = 32
    TIME_LENGTH = 10
    RANDOM_LENGTH = 16
    LENGTH = TIME_LENGTH + RANDOM_LENGTH

    PATTERN = /\A[0-7][#{ENCODING}]{25}\z/

    MUTEX = Mutex.new
    private_constant :MUTEX

    class << self
      # Returns a new ULID. `moment` is accepted so tests and importers can
      # produce deterministic, correctly ordered identifiers.
      #
      # Identifiers generated within the same millisecond increment instead of
      # re-randomizing, so a batch of events captured together still sorts in
      # the order it was written. That matters for exports and for reading a
      # lifecycle chain by identifier alone.
      def generate(moment = Time.now)
        MUTEX.synchronize { monotonic_ulid(encode_time(moment)) }
      end

      def valid?(value)
        PATTERN.match?(value.to_s)
      end

      # Returns the Time encoded in the identifier, or nil when it is not a
      # ULID. Callers must not treat this as the recorded server time.
      def time_from(value)
        return nil unless valid?(value)

        milliseconds = value.to_s[0, TIME_LENGTH].each_char.reduce(0) do |total, char|
          (total * ENCODING_LENGTH) + ENCODING.index(char)
        end

        Time.at(milliseconds / 1000.0).utc
      end

      private

      def monotonic_ulid(time_part)
        @last_time_part = nil unless defined?(@last_time_part)

        random_part =
          if time_part == @last_time_part
            increment(@last_random_part)
          else
            encode_random
          end

        @last_time_part = time_part
        @last_random_part = random_part
        time_part + random_part
      end

      # Adds one to a Crockford base32 string, rolling over from the right. On
      # the vanishingly unlikely overflow of every character in one
      # millisecond, start from a fresh random value rather than wrapping to a
      # smaller identifier.
      def increment(random_part)
        characters = random_part.chars

        (characters.length - 1).downto(0) do |index|
          position = ENCODING.index(characters[index])

          if position < ENCODING_LENGTH - 1
            characters[index] = ENCODING[position + 1]
            return characters.join
          end

          characters[index] = ENCODING[0]
        end

        encode_random
      end

      def encode_time(moment)
        milliseconds = (moment.to_f * 1000).floor
        buffer = +""

        TIME_LENGTH.times do
          buffer.prepend(ENCODING[milliseconds % ENCODING_LENGTH])
          milliseconds /= ENCODING_LENGTH
        end

        buffer
      end

      def encode_random
        Array.new(RANDOM_LENGTH) { ENCODING[SecureRandom.random_number(ENCODING_LENGTH)] }.join
      end
    end
  end
end
