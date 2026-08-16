# frozen_string_literal: true

module Clickwrap
  # What came back from the browser: a signed presentation token and the
  # answers to the statements that token declared.
  #
  # Nothing else. A submission cannot carry a policy key, a document version, a
  # validity date, a retention rule, a subject, an IP address, a user-agent, or
  # a geolocation, because every one of those is a decision the server makes and
  # a form field is not a safe place to keep one. Unknown keys are rejected
  # rather than ignored, so an attempt to smuggle one in fails loudly instead of
  # silently doing nothing and looking like it worked.
  class Submission
    ENVELOPE_KEY = :clickwrap_submission
    ENVELOPE_KEYS = %w[presentation_token answers].freeze

    # Names a client must never be able to set. They exist as a check rather
    # than a filter: a request containing one is a request worth failing.
    REFUSED_KEYS = %w[
      policy policy_key policy_revision revision document document_version version
      valid_from valid_until expires_at retention retain_until subject subject_id
      actor actor_id tenant ip_address remote_ip browser_user_agent user_agent
      ip_geolocation geolocation latitude longitude resolver recorded_at
      server_observed_ip_address capture_channel authentication_method
    ].freeze

    # The longest an answer can be: generous for any declared choice name,
    # far too short for smuggled prose or a payload.
    MAX_ANSWER_LENGTH = 120

    attr_reader :presentation_token, :answers

    def initialize(presentation_token:, answers: {})
      @presentation_token = presentation_token
      @answers = normalize_answers(answers)
      freeze
    end

    class << self
      # Reads the generated envelope out of controller params.
      def from_params(params, key: ENVELOPE_KEY)
        envelope = extract_envelope(params, key)

        raise SubmissionInvalid, missing_envelope_message(key) if envelope.nil?

        new(
          presentation_token: envelope["presentation_token"] || envelope[:presentation_token],
          answers: envelope["answers"] || envelope[:answers] || {}
        )
      end

      def missing_envelope_message(key)
        "The request contains no #{key} parameter. The form helper renders it; a custom form " \
          "must include the signed presentation token from Clickwrap.present."
      end

      private

      def extract_envelope(params, key)
        envelope = params[key] || params[key.to_s]
        return nil if envelope.nil?

        raw = if envelope.respond_to?(:to_unsafe_h)
                # This is an evidence/security parser, not a mass-assignment
                # boundary. `permit` would silently erase unknown fields before
                # we could refuse them, making a forged server-owned field look
                # as though it worked. Read the envelope, validate its complete
                # shape below, and only then select the two values we understand.
                envelope.to_unsafe_h
              elsif envelope.is_a?(Hash)
                envelope.to_h
              end

        unless raw
          raise SubmissionInvalid,
                "The #{key} parameter must be an object containing a presentation_token and " \
                "an answers object. It was #{envelope.class}; Clickwrap did not try to guess " \
                "how to reinterpret it."
        end

        normalized_keys = raw.keys.map(&:to_s)
        duplicate_keys = normalized_keys.tally.select { |_, count| count > 1 }.keys
        unknown_keys = normalized_keys.uniq - ENVELOPE_KEYS
        if duplicate_keys.any? || unknown_keys.any?
          problems = []
          problems << "duplicate keys #{duplicate_keys.join(", ")}" if duplicate_keys.any?
          problems << "unknown keys #{unknown_keys.join(", ")}" if unknown_keys.any?
          raise SubmissionInvalid,
                "The #{key} envelope contains #{problems.join(" and ")}. It may contain only " \
                "presentation_token and answers; policy, authority, identity, retention, and " \
                "request-evidence decisions are server-owned."
        end

        raw
      end
    end

    # Deliberately not memoized: a Submission is frozen the moment it is built,
    # so an instance variable written on first use would raise. Verifying the
    # token again costs one signature check, which is a small price for an
    # object that cannot be tampered with after construction.
    def manifest
      PresentationManifest.from_token(presentation_token)
    end

    def answer_for(statement_key) = answers[statement_key.to_s]

    def answered?(statement_key)
      self.class.affirmative?(answer_for(statement_key))
    end

    def self.affirmative?(value)
      return false if value.nil?

      !%w[0 false off no].include?(value.to_s.downcase) && value.to_s != ""
    end

    def to_h
      { "presentation_token" => presentation_token, "answers" => answers }
    end

    private

    # Answers are scalars keyed by statement. A nested structure would be a way
    # to smuggle something structured past a check that expected a checkbox.
    def normalize_answers(raw)
      hash = if raw.respond_to?(:to_unsafe_h)
               raw.to_unsafe_h
             elsif raw.is_a?(Hash)
               raw.to_h
             else
               raise SubmissionInvalid,
                     "The clickwrap answers parameter must be an object keyed by statement. It " \
                     "was #{raw.class}; each answer must be a single checkbox state or declared choice."
             end

      hash.to_h do |key, value|
        name = key.to_s

        if REFUSED_KEYS.include?(name)
          raise SubmissionInvalid,
                "The submitted answers include #{name.inspect}, which is a server-owned " \
                "decision. Clickwrap resolves the policy, document versions, validity, subject, " \
                "retention, and request evidence itself; a browser cannot choose any of them."
        end

        unless value.is_a?(String) || value.is_a?(Symbol) || [true, false, nil].include?(value) ||
               value.is_a?(Numeric)
          raise SubmissionInvalid,
                "The answer for #{name.inspect} is a #{value.class}. Answers are single values: " \
                "a checkbox state or the name of one declared choice."
        end

        # Answers are the one client-authored value that becomes digested
        # evidence, so their domain is bounded: a checkbox state or a declared
        # choice name is never longer than this. Refused, never truncated —
        # evidence is recorded exactly or not at all.
        if value.to_s.length > MAX_ANSWER_LENGTH
          raise SubmissionInvalid,
                "The answer for #{name.inspect} is #{value.to_s.length} characters. An answer " \
                "is a checkbox state or the name of one declared choice, never free text; " \
                "anything over #{MAX_ANSWER_LENGTH} characters is refused rather than recorded."
        end

        [name, value.nil? ? nil : value.to_s]
      end.freeze
    end
  end
end
