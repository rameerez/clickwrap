# frozen_string_literal: true

module Clickwrap
  # Development and test heuristics for the presentation layer.
  #
  # ============================================================================
  # THESE ARE HEURISTICS. They warn; they never raise, never block a render, and
  # never certify anything. A clean run means "none of the specific hazards
  # below were detected in what was inspected" and nothing else.
  #
  # This class must never print, return, or imply "compliant", "enforceable",
  # "legally binding", "accessible", or "approved". Courts assess the complete
  # page in context and accessibility applies to the whole experience, so no
  # library that sees one fragment of one template can make any of those calls.
  # What it can do is notice objectively checkable mistakes — a submit button
  # above the controls, a consent box that arrives already ticked, a document
  # nobody can open — and say so in a full sentence.
  # ============================================================================
  #
  #   findings = Clickwrap::Linter.review_policy(Clickwrap.policy!(:signup))
  #   findings.map(&:code)         # => [:consent_statement_bundles_purposes]
  #   findings.first.explanation   # => a plain-English sentence
  #
  # Every finding carries a stable symbol, so a test can assert on it without
  # matching English, and an explanation, so a person reading the log knows what
  # to do about it.
  class Linter
    Finding = Data.define(:code, :explanation, :context) do
      def to_s = "#{code}: #{explanation}"
    end

    # Rendered-fragment scans, kept to string work so they are cheap enough to
    # run on every development render.
    ANSWER_FIELD_PATTERN = /name=["']clickwrap_submission\[answers\]\[([^\]"']+)\]["']/
    TOKEN_FIELD_PATTERN = /name=["']clickwrap_submission\[presentation_token\]["']/
    SUBMIT_CONTROL_PATTERN = /<(?:button|input)\b[^>]*type=["']submit["']|<button(?![^>]*type=)/i
    CHECKED_ATTRIBUTE_PATTERN = /\bchecked\b/

    # A rough test for a consent sentence that is carrying more than one
    # purpose. It is deliberately generous: the cost of a false positive is one
    # log line suggesting a split, and the cost of a false negative is a consent
    # record whose meaning nobody can reconstruct.
    BUNDLED_PURPOSE_PATTERN = %r{\b(and|and/or|as well as|plus)\b}i

    class << self
      # On in development and test, off everywhere else. A production request
      # should not be scanning its own HTML.
      def enabled?
        return false unless defined?(::Rails) && ::Rails.respond_to?(:env) && ::Rails.env

        ::Rails.env.development? || ::Rails.env.test?
      end

      # --- Entry points -------------------------------------------------------

      # What a compiled policy alone can be checked for, without rendering
      # anything: blank copy, bundled consent purposes, and an optional consent
      # that another statement has quietly made mandatory.
      def review_policy(policy, locale: nil)
        locale = (locale || (defined?(::I18n) ? ::I18n.locale : :en)).to_s

        findings = []
        findings.concat(blank_assertion_findings(policy))
        findings.concat(bundled_consent_findings(policy, locale))
        findings.concat(optional_consent_prerequisite_findings(policy))
        findings
      end

      # What one presentation can be checked for: a statement the person is
      # asked to accept with no way to read what they are accepting.
      def review_presentation(presentation)
        presentation.statements.filter_map do |statement|
          next if statement.documents.any?
          next unless %w[agreement acknowledgment consent].include?(statement.kind)

          Finding.new(
            code: :document_link_missing,
            explanation: "The #{statement.kind} #{statement.key.inspect} presents no document, so " \
                         "the person is asked to accept something the page never shows them. Give " \
                         "the statement a `document:` and publish it.",
            context: { statement: statement.key, policy: presentation.policy_key }
          )
        end
      end

      # Whether the manifest that came back still says what the policy says.
      # A difference here means the evidence and the current server-owned offer
      # have diverged — usually a deploy between render and submit, sometimes a
      # hand-built form that stopped tracking the policy.
      def review_manifest(manifest, policy:)
        snapshot = manifest.respond_to?(:to_h) ? manifest.to_h : manifest
        rendered = Array(snapshot["statements"] || snapshot[:statements])
        differences = manifest_differences(rendered, policy: policy, locale: snapshot["locale"])
        return [] if differences.empty?

        [Finding.new(
          code: :rendered_manifest_differs_from_policy,
          explanation: "The submitted presentation manifest does not match the current policy " \
                       "#{policy.key}: #{differences.join("; ")}. Clickwrap verifies this at " \
                       "capture; the warning is here so the drift is visible while you can still " \
                       "explain it.",
          context: { policy: policy.key, differences: differences }
        )]
      end

      # What the rendered HTML can be checked for. Pass the whole page when you
      # have it — the CTA-ordering check needs everything before the block, not
      # just the block.
      def review_rendered_html(html, presentation: nil)
        text = html.to_s
        findings = []
        findings.concat(submit_ordering_findings(text))
        findings.concat(preselected_control_findings(text))
        findings.concat(rendered_document_link_findings(text, presentation)) if presentation
        findings
      end

      # Called by the form-builder helper on every development render. Scans
      # only the fragment it produced, so it deliberately skips the CTA-ordering
      # check (a submit button earlier in the host's page is invisible from
      # here — that one belongs in a system test over the whole page).
      def review_rendered_fields(html, presentation:)
        findings = preselected_control_findings(html.to_s)
        findings.concat(rendered_document_link_findings(html.to_s, presentation))
        findings.concat(review_presentation(presentation))
        warn_about(findings, source: "policy #{presentation.policy_key}")
        findings
      end

      # Warnings go to the Rails log, or to stderr when there is no log. Never
      # an exception: a lint finding is a thing to look at, not a reason to stop
      # a developer's page from rendering.
      def warn_about(findings, source: nil)
        Array(findings).each do |finding|
          message = ["[clickwrap] lint", source, "#{finding.code}: #{finding.explanation}"]
                    .compact.join(" — ")

          logger = Clickwrap.logger
          logger ? logger.warn(message) : Kernel.warn(message)
        end

        findings
      end

      private

      # --- Policy checks ------------------------------------------------------

      def blank_assertion_findings(policy)
        policy.statements.filter_map do |statement|
          next if statement.assertion.present?

          Finding.new(
            code: :assertion_text_blank,
            explanation: "Statement #{statement.key.inspect} has no assertion text. The sentence " \
                         "beside the control is what the receipt records, so a blank one records " \
                         "nothing meaningful.",
            context: { policy: policy.key, statement: statement.key }
          )
        end
      end

      def bundled_consent_findings(policy, locale)
        policy.consent_statements.filter_map do |statement|
          reasons = []
          reasons << "it presents #{statement.document_keys.size} documents" if statement.document_keys.size > 1
          if BUNDLED_PURPOSE_PATTERN.match?(resolved_assertion(statement, locale))
            reasons << "its sentence joins more than one thing with a conjunction"
          end
          next if reasons.empty?

          Finding.new(
            code: :consent_statement_bundles_purposes,
            explanation: "Consent statement #{statement.key.inspect} may cover more than one " \
                         "purpose (#{reasons.join(" and ")}). One control per purpose keeps each " \
                         "grant separately withdrawable and keeps the receipt able to say which " \
                         "purpose was actually agreed to.",
            context: { policy: policy.key, statement: statement.key }
          )
        end
      end

      # The words a person would actually read, which is what these heuristics
      # are about. An assertion declared as an I18n key says nothing on its own;
      # when it cannot be resolved (no translation yet), fall back to the
      # declaration rather than turning a lint pass into a failure.
      def resolved_assertion(statement, locale)
        statement.resolve_copy(locale: locale)["assertion"].to_s
      rescue StandardError
        statement.assertion.to_snapshot.to_s
      end

      def optional_consent_prerequisite_findings(policy)
        optional_consents = policy.consent_statements.select(&:optional?).map(&:key)
        return [] if optional_consents.empty?

        policy.statements.flat_map do |statement|
          (statement.requires & optional_consents).map do |consent_key|
            Finding.new(
              code: :optional_consent_required_for_another_action,
              explanation: "#{statement.key.inspect} requires the optional consent " \
                           "#{consent_key.inspect}, which makes an optional control mandatory for " \
                           "an action it is not part of. Either drop `optional: true` and say " \
                           "plainly that it is required, or stop requiring it here.",
              context: { policy: policy.key, statement: statement.key, consent: consent_key }
            )
          end
        end
      end

      # --- Manifest checks ----------------------------------------------------

      def manifest_differences(rendered, policy:, locale:)
        rendered_keys = rendered.map { |fragment| fragment["key"] || fragment[:key] }
        policy_keys = policy.statements.map(&:key)

        differences = (policy_keys - rendered_keys).map { |key| "#{key} is in the policy but absent from the manifest" }
        (rendered_keys - policy_keys).each { |key| differences << "#{key} is in the manifest but not the policy" }

        rendered.each do |fragment|
          statement = policy.statement(fragment["key"] || fragment[:key])
          next if statement.nil?

          differences.concat(statement_differences(fragment, statement, locale))
        end

        differences
      end

      def statement_differences(fragment, statement, locale)
        differences = []
        differences << "#{statement.key} is recorded in the manifest as required=#{fragment["required"]}" if
          fragment.key?("required") && fragment["required"] != statement.required?

        resolved_locale = (locale || (defined?(::I18n) ? ::I18n.locale : :en)).to_s
        resolved = statement.resolve_copy(locale: resolved_locale)["assertion"]
        differences << "#{statement.key} has different wording in the manifest" if
          fragment["assertion"].present? && resolved.present? && fragment["assertion"] != resolved

        differences
      end

      # --- Rendered-HTML checks -----------------------------------------------

      def submit_ordering_findings(html)
        first_control = html.index(ANSWER_FIELD_PATTERN) || html.index(TOKEN_FIELD_PATTERN)
        return [] if first_control.nil?

        first_submit = html.index(SUBMIT_CONTROL_PATTERN)
        return [] if first_submit.nil? || first_submit > first_control

        [Finding.new(
          code: :submit_control_before_clickwrap_block,
          explanation: "A submit control appears before the Clickwrap controls in this page. " \
                       "Someone can reach the action without having passed what they are being " \
                       "asked to accept; put the block immediately before the call to action it " \
                       "belongs to.",
          context: { submit_at: first_submit, controls_at: first_control }
        )]
      end

      def preselected_control_findings(html)
        findings = []
        position = 0

        while (match = ANSWER_FIELD_PATTERN.match(html, position))
          position = match.end(0)
          statement_key = match[1]
          next unless CHECKED_ATTRIBUTE_PATTERN.match?(surrounding_tag(html, match.begin(0)))

          findings << Finding.new(
            code: :consent_control_preselected,
            explanation: "The control for #{statement_key.inspect} is rendered already selected. " \
                         "A pre-ticked box records the page's default rather than a person's " \
                         "action; controls must start empty and stay empty until someone acts.",
            context: { statement: statement_key }
          )
        end

        findings
      end

      def rendered_document_link_findings(html, presentation)
        presentation.statements.flat_map do |statement|
          statement.documents.filter_map do |document|
            next if document.path.present? && html.include?(document.path)
            next if document.label.present? && html.include?(document.label)

            Finding.new(
              code: :document_link_missing,
              explanation: "#{document.key.inspect} is part of #{statement.key.inspect} but no " \
                           "link to it was rendered, so the document is not reachable from the " \
                           "page where it is being accepted.",
              context: { statement: statement.key, document: document.key }
            )
          end
        end
      end

      # The opening tag the match sits inside, so `checked` on a neighboring
      # element is not mistaken for `checked` on this control.
      def surrounding_tag(html, position)
        start = html.rindex("<", position) || position
        finish = html.index(">", position) || html.length
        html[start..finish]
      end
    end
  end
end
