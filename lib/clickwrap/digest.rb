# frozen_string_literal: true

require "digest"
require "openssl"

module Clickwrap
  # Digest helpers for document bytes, presentation manifests, receipts, and the
  # optional event chain.
  #
  # What a digest here does and does not mean is part of the public contract.
  # A digest detects that the bytes it covers changed. It does not identify who
  # produced them, when they were produced, or that a party with full control
  # of the database and application could not have rewritten both the bytes and
  # the digest. Stronger claims need the optional independent anchor or
  # timestamp adapters, and even then Clickwrap reports exactly the assurance
  # those adapters supply.
  #
  # SHA-2 is a hash standard (NIST FIPS 180-4,
  # https://csrc.nist.gov/pubs/fips/180-4/upd1/final). It is not a signature,
  # not an identity, and not a time source.
  module Digest
    # Algorithm name => the OpenSSL digest that computes it. Every value stored
    # in evidence carries its algorithm name so a future release can add an
    # algorithm without making old events unverifiable.
    SUPPORTED_ALGORITHMS = {
      "sha256" => "SHA256",
      "sha384" => "SHA384",
      "sha512" => "SHA512"
    }.freeze

    DEFAULT_ALGORITHM = "sha256"

    # Digests are written as "<algorithm>:<lowercase hex>" everywhere they
    # appear, so an auditor never has to guess which function produced a bare
    # hex string.
    PREFIXED_PATTERN = /\A(?<algorithm>[a-z0-9]+):(?<value>[0-9a-f]+)\z/

    class << self
      # Returns "sha256:<hex>" for the given bytes.
      def digest(bytes, algorithm: DEFAULT_ALGORITHM)
        "#{algorithm}:#{hex(bytes, algorithm:)}"
      end

      # Returns the bare lowercase hex digest.
      def hex(bytes, algorithm: DEFAULT_ALGORITHM)
        OpenSSL::Digest.hexdigest(openssl_name(algorithm), bytes.to_s.b)
      end

      # Canonicalizes `value` per RFC 8785 and digests the resulting bytes.
      # This is how manifests, compiled policy revisions, and receipts are
      # digested: the digest covers meaning, not formatting.
      def digest_canonical(value, algorithm: DEFAULT_ALGORITHM)
        digest(CanonicalJson.generate(value), algorithm:)
      end

      # A keyed digest, used where an unkeyed one would be guessable.
      #
      # An IPv4 address is 32 bits (RFC 791), so an unsalted hash of one can be
      # tested by enumerating every address in minutes. Clickwrap therefore
      # binds request evidence to its event with a keyed construction and says
      # plainly that the result is a linkable pseudonymous value, not an
      # anonymous one.
      def keyed_digest(bytes, key:, algorithm: DEFAULT_ALGORITHM)
        raise ArgumentError, "A keyed digest needs a key" if key.nil? || key.to_s.empty?

        mac = OpenSSL::HMAC.hexdigest(openssl_name(algorithm), key.to_s, bytes.to_s.b)
        "hmac-#{algorithm}:#{mac}"
      end

      # Compares two digest strings without leaking timing information.
      def secure_compare?(left, right)
        return false if left.nil? || right.nil?

        OpenSSL.secure_compare(left.to_s, right.to_s)
      end

      def algorithm_of(prefixed)
        PREFIXED_PATTERN.match(prefixed.to_s)&.[](:algorithm)
      end

      def supported?(algorithm)
        SUPPORTED_ALGORITHMS.key?(algorithm.to_s)
      end

      # Verifies that `bytes` still hash to `expected`, which must be a
      # prefixed digest so the algorithm travels with the value.
      def matches?(bytes, expected)
        match = PREFIXED_PATTERN.match(expected.to_s)
        return false unless match

        algorithm = match[:algorithm]
        return false unless supported?(algorithm)

        secure_compare?(hex(bytes, algorithm:), match[:value])
      end

      private

      def openssl_name(algorithm)
        SUPPORTED_ALGORITHMS.fetch(algorithm.to_s) do
          raise ConfigurationError,
                "#{algorithm.inspect} is not a supported digest algorithm. " \
                "Choose one of: #{SUPPORTED_ALGORITHMS.keys.join(', ')}."
        end
      end
    end
  end
end
