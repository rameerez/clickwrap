# frozen_string_literal: true

require "test_helper"

# RFC 8785 conformance.
#
# This is the foundation everything else rests on: if two implementations
# disagree about the bytes, every digest in every receipt is worthless. So these
# tests check the spec's own worked example and the number formatting rules
# rather than checking that the code agrees with itself.
#
# https://www.rfc-editor.org/rfc/rfc8785
class CanonicalJsonTest < ActiveSupport::TestCase
  C = Clickwrap::CanonicalJson

  # --- Object key ordering ----------------------------------------------------

  test "object keys sort by UTF-16 code unit, matching the example in RFC 8785 section 3.2.3" do
    input = {
      "\u20ac" => "Euro Sign",
      "\r" => "Carriage Return",
      "\uFB33" => "Hebrew Letter Dalet + Dagesh",
      "1" => "One",
      "\u{1F600}" => "Emoji: Grinning Face",
      "\u0080" => "Control",
      "\u00F6" => "Latin Small Letter O With Diaeresis"
    }

    expected = "{" \
               "\"\\r\":\"Carriage Return\"," \
               "\"1\":\"One\"," \
               "\"\u0080\":\"Control\"," \
               "\"\u00F6\":\"Latin Small Letter O With Diaeresis\"," \
               "\"\u20AC\":\"Euro Sign\"," \
               "\"\u{1F600}\":\"Emoji: Grinning Face\"," \
               "\"\uFB33\":\"Hebrew Letter Dalet + Dagesh\"" \
               "}"

    assert_equal expected, C.generate(input)
  end

  test "the emoji sorts before the Hebrew letter, which byte ordering would get backwards" do
    # U+1F600 is the surrogate pair D83D DE00 in UTF-16, and 0xD83D < 0xFB33.
    # Ruby's own String#<=> compares UTF-8 bytes and would order these the other
    # way round, which is exactly the bug this rule exists to prevent.
    result = C.generate({ "\uFB33" => 1, "\u{1F600}" => 2 })

    assert_operator result.index("\u{1F600}"), :<, result.index("\uFB33")
  end

  test "nested objects are sorted at every level" do
    assert_equal '{"a":"x","b":[1,2,{"a":true,"z":null}]}',
                 C.generate({ "b" => [1, 2, { "z" => nil, "a" => true }], "a" => "x" })
  end

  test "symbol keys and values serialize as their strings" do
    assert_equal '{"a":"b"}', C.generate({ a: :b })
  end

  # --- Numbers ----------------------------------------------------------------

  test "numbers follow the ECMAScript rules RFC 8785 defers to, not Ruby's Float#to_s" do
    {
      1.0 => "1",
      0.0 => "0",
      100.0 => "100",
      0.1 => "0.1",
      123.456 => "123.456",
      # Ruby writes 1.0e-05 here; ECMAScript writes the expanded form until the
      # exponent passes -7.
      0.00001 => "0.00001",
      1e-6 => "0.000001",
      1e-7 => "1e-7",
      # ...and switches to exponential at 1e21, not before.
      1e20 => "100000000000000000000",
      1e21 => "1e+21",
      9_007_199_254_740_992.0 => "9007199254740992",
      5e-324 => "5e-324",
      333_333_333.33333329 => "333333333.3333333"
    }.each do |input, expected|
      assert_equal expected, C.generate(input), "#{input.inspect} serialized incorrectly"
    end
  end

  test "negative zero serializes as zero" do
    # Tested on its own because -0.0 and 0.0 are the same Hash key in Ruby, so
    # the table above cannot hold both. RFC 8785 requires "0" for either.
    assert_equal "0", C.generate(-0.0)
  end

  test "integers serialize without a decimal point" do
    assert_equal "42", C.generate(42)
    assert_equal "-42", C.generate(-42)
    assert_equal "0", C.generate(0)
  end

  # --- Strings ----------------------------------------------------------------

  test "only the characters JSON requires are escaped" do
    assert_equal '"line\nbreak\u0001\"q\"\\\\"', C.generate("line\nbreak\u0001\"q\"\\")
  end

  test "non-ASCII characters are emitted as UTF-8 rather than escaped" do
    assert_equal '"café €"', C.generate("café €")
  end

  test "the forward slash is not escaped" do
    assert_equal '"a/b"', C.generate("a/b")
  end

  test "the output is UTF-8" do
    assert_equal Encoding::UTF_8, C.generate({ "a" => "é" }).encoding
  end

  # --- Round-tripping ---------------------------------------------------------

  test "canonicalizing is idempotent" do
    json = C.generate({ "b" => [1, 2.5, nil, true], "a" => { "z" => "é" } })

    assert_equal json, C.canonicalize(json)
    assert C.canonical?(json)
  end

  test "canonical? is false for JSON that merely parses" do
    assert_not C.canonical?('{"b":1,"a":2}')
    assert_not C.canonical?('{ "a": 1 }')
    assert_not C.canonical?("not json at all")
  end

  # --- What it refuses --------------------------------------------------------

  test "a value that cannot appear in JSON is refused rather than coerced" do
    # Coercing would produce bytes that depend on Ruby's inspect output, which
    # no other implementation could reproduce.
    error = assert_raises(Clickwrap::CanonicalJson::SerializationError) do
      C.generate({ "a" => Object.new })
    end

    assert_match(/canonical JSON/, error.message)
  end

  test "an integer too large for a double is refused" do
    # RFC 8785 assumes IEEE 754 doubles. Serializing a larger integer would
    # produce bytes another verifier would read back as a different number.
    assert_raises(Clickwrap::CanonicalJson::SerializationError) { C.generate(2**60) }
    assert_equal "9007199254740991", C.generate(Clickwrap::CanonicalJson::MAX_EXACT_INTEGER)
  end

  test "NaN and Infinity are refused" do
    assert_raises(Clickwrap::CanonicalJson::SerializationError) { C.generate(Float::NAN) }
    assert_raises(Clickwrap::CanonicalJson::SerializationError) { C.generate(Float::INFINITY) }
    assert_raises(Clickwrap::CanonicalJson::SerializationError) { C.generate(-Float::INFINITY) }
  end

  test "duplicate keys are refused rather than silently collapsed" do
    error = assert_raises(Clickwrap::CanonicalJson::SerializationError) do
      C.generate({ "a" => 1, :a => 2 })
    end

    assert_match(/Duplicate object key/, error.message)
  end

  test "a non-string object key is refused" do
    assert_raises(Clickwrap::CanonicalJson::SerializationError) { C.generate({ 1 => "x" }) }
  end

  test "invalid UTF-8 is refused" do
    assert_raises(Clickwrap::CanonicalJson::SerializationError) do
      C.generate((+"\xC3").force_encoding(Encoding::UTF_8))
    end
  end

  # --- Digests over canonical bytes -------------------------------------------

  test "a canonical digest is stable across key ordering" do
    assert_equal Clickwrap::Digest.digest_canonical({ "b" => 1, "a" => 2 }),
                 Clickwrap::Digest.digest_canonical({ "a" => 2, "b" => 1 })
  end

  test "a canonical digest changes when a value changes" do
    assert_not_equal Clickwrap::Digest.digest_canonical({ "a" => 1 }),
                     Clickwrap::Digest.digest_canonical({ "a" => 2 })
  end

  test "digests are algorithm-prefixed so a bare hex string is never ambiguous" do
    digest = Clickwrap::Digest.digest("hello")

    assert_match(/\Asha256:[0-9a-f]{64}\z/, digest)
    assert_equal "sha256", Clickwrap::Digest.algorithm_of(digest)
    assert Clickwrap::Digest.matches?("hello", digest)
    assert_not Clickwrap::Digest.matches?("hellp", digest)
  end

  test "an unsupported digest algorithm is refused by name" do
    error = assert_raises(Clickwrap::ConfigurationError) { Clickwrap::Digest.digest("x", algorithm: "md5") }

    assert_match(/supported digest algorithm/, error.message)
  end

  test "a keyed digest needs a key, because an unsalted hash of a small domain is guessable" do
    # An IPv4 address is 32 bits. An unsalted hash of one can be tested by
    # enumeration in minutes, so calling it anonymized would be wrong.
    assert_raises(ArgumentError) { Clickwrap::Digest.keyed_digest("1.2.3.4", key: nil) }

    keyed = Clickwrap::Digest.keyed_digest("1.2.3.4", key: "a-key")
    assert keyed.start_with?("hmac-sha256:")
    assert_not_equal keyed, Clickwrap::Digest.keyed_digest("1.2.3.4", key: "another-key")
  end
end
