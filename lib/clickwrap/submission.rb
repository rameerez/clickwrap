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

    # Names a client must never be able to set. They exist as a check rather
    # than a filter: a request containing one is a request worth failing.
    REFUSED_KEYS = %w[
      policy policy_key policy_revision revision document document_version version
      valid_from valid_until expires_at retention retain_until subject subject_id
      actor actor_id tenant ip_address remote_ip browser_user_agent user_agent
      ip_geolocation geolocation latitude longitude resolver recorded_at
      server_observed_ip_address capture_channel authentication_method
    ].freeze

    attr_reader :presentation_token, :answers, :client_reported_context

    def initialize(presentation_token:, answers: {}, client_reported_context: nil)
      @presentation_token = presentation_token
      @answers = normalize_answers(answers)
      @client_reported_context = client_reported_context
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

        if envelope.respond_to?(:permit!)
          envelope.permit(:presentation_token, answers: {}).to_h
        else
          envelope.to_h
        end
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
      value = answer_for(statement_key)
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
      hash = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw.to_h

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

        [name, value.nil? ? nil : value.to_s]
      end.freeze
    end
  end
end
