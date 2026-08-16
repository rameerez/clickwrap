# frozen_string_literal: true

module Clickwrap
  # Test helpers for Minitest.
  # Include in your test helper to get evidence-related test utilities.
  #
  # @example Include in test_helper.rb
  #   require "clickwrap/test_helpers"
  #
  #   class ActiveSupport::TestCase
  #     include Clickwrap::TestHelpers
  #
  #     setup    { Clickwrap::Testing.reset! }
  #     teardown { Clickwrap::Testing.reset! }
  #   end
  #
  # @example Using in tests
  #   test "signup records the terms agreement" do
  #     receipt = capture_clickwrap(:signup, actor: @user,
  #                                 answers: { terms: true, privacy_notice: true })
  #
  #     assert_clickwrap_current :signup, actor: @user
  #     assert_clickwrap_agreed_to :terms, actor: @user
  #     assert_clickwrap_acknowledged :privacy_notice, actor: @user
  #     assert_clickwrap_receipt_verifies receipt
  #   end
  #
  # @example Proving the atomicity promise
  #   test "a failed evidence write rolls the account back" do
  #     Clickwrap::Testing.fail_next_event_write do
  #       assert_raises(Clickwrap::EventWriteFailed) { perform_signup }
  #     end
  #
  #     assert_not User.exists?(email: "person@example.com")
  #     assert_no_clickwrap_event :signup
  #   end
  #
  # ===========================================================================
  # EVERY HELPER HERE GOES THROUGH THE REAL PATH.
  #
  # `capture_clickwrap` presents the policy through the actual Presenter, takes
  # the signed token it produced, builds an actual `Clickwrap::Submission` from
  # it, and calls the actual `Clickwrap.capture!`. It does not insert rows.
  #
  # That is not fastidiousness. Hand-built evidence rows are the single most
  # effective way to make a suite green while the product is broken: they skip
  # the manifest, the digests, the answer validation, the idempotency key, the
  # projection, and the very checks the gem exists to perform, and then every
  # assertion downstream is checking that a fixture matches itself. Evidence
  # created by these helpers is internally consistent because it was created
  # the same way real evidence is.
  #
  # The deliberately-broken cases — an expired presentation, a stale revision,
  # another actor's token — are built by taking a REAL presentation and
  # changing exactly one thing about it, so what fails is the server's own
  # check rather than a mock standing in for it.
  # ===========================================================================
  module TestHelpers
    # Opt-in class macro for integration tests that must reach real commit
    # callbacks instead of Rails' normal transactional-test rollback boundary.
    module ClassMethods
      # Sensitive exports deliberately refuse to reveal data from inside an
      # outer transaction: their access audit must commit before bytes leave
      # the process. Rails wraps tests in transactions by default, so tests of
      # that production contract can opt into real commits explicitly.
      #
      # This also installs deterministic cleanup around each such test. It is a
      # test-only facility; production code never truncates host tables.
      def use_real_database_commits!
        self.use_transactional_tests = false

        setup do
          reset_clickwrap_test_database!
          publish_clickwrap_documents!
        end

        teardown { reset_clickwrap_test_database! }
      end
    end

    def self.included(base)
      base.extend(ClassMethods)
    end

    # --- Presenting and capturing ---------------------------------------------

    # Presents a policy server-side and returns the Presenter::Result, whose
    # `token` is a real signed presentation token.
    #
    # @param policy_key [Symbol, String] the policy to present
    # @param actor [Object, nil] the record acting, or nil for a registration flow
    # @param submit_button_text [String] the exact call to action, recorded in the manifest
    # @return [Clickwrap::Presenter::Result]
    def present_clickwrap(policy_key, actor: nil, subject: nil, tenant: nil, locale: nil,
                          submit_button_text: "Continue", capture_channel: :web_browser,
                          prospective_actor: nil, registration_flow_id: nil, acting_for: nil)
      registration_flow_id ||= SecureRandom.uuid if prospective_actor

      Presenter.new(
        policy: Clickwrap.policy!(policy_key),
        actor: actor,
        prospective_actor: prospective_actor,
        registration_flow_id: registration_flow_id,
        subject: subject,
        tenant: tenant,
        acting_for: acting_for,
        locale: locale,
        submit_button_text: submit_button_text,
        capture_channel: capture_channel
      ).present
    end
    module_function :present_clickwrap
    # module_function makes the INSTANCE copy private — fine for included test
    # usage (implicit receiver) while enabling the module-level call, for
    # suites whose own factory names would collide with this module's.
    public :present_clickwrap

    # Builds a real Submission from a presentation result.
    #
    # @param presentation_result [Clickwrap::Presenter::Result]
    # @param answers [Hash] statement key => answer
    # @return [Clickwrap::Submission]
    def submission_for(presentation_result, answers = {})
      Submission.new(
        presentation_token: presentation_result.token,
        answers: answers.transform_keys(&:to_s)
      )
    end
    module_function :submission_for
    public :submission_for

    # The one-line form of the pattern below, for integration tests: GET the
    # page that renders a clickwrap presentation, read the signed token and
    # controls back out of it, return the params for the POST.
    #
    #   post user_registration_path, params: {
    #     user: { ... },
    #     **clickwrap_params_from(new_user_registration_path)
    #   }
    def clickwrap_params_from(path, answers: {}, form_css_selector: nil)
      unless respond_to?(:get)
        raise ArgumentError,
              "clickwrap_params_from drives a real GET, so it needs an integration test " \
              "(ActionDispatch::IntegrationTest). In other tests, build the submission with " \
              "present_clickwrap + submission_for instead."
      end

      get path
      clickwrap_submission_params_from(
        response,
        answers: answers,
        form_css_selector: form_css_selector
      )
    end
    module_function :clickwrap_params_from
    public :clickwrap_params_from

    # For integration tests that POST a form the application really rendered —
    # the signed presentation token is minted per render and bound to the
    # session, so a test cannot fabricate it; it has to read it back out of
    # the page, exactly like a browser:
    #
    #   get new_user_registration_path
    #   post user_registration_path, params: {
    #     user: { email: "person@example.com", password: "..." },
    #     **clickwrap_submission_params_from(response)
    #   }
    #
    # Every control the page rendered is answered affirmatively by default —
    # what a person completing the form normally does. Decline or skip one
    # explicitly with `answers:`:
    #
    #   clickwrap_submission_params_from(response, answers: { product_updates: false })
    #
    # A page with several independent clickwrap forms must name the exact form.
    # The helper refuses ambiguity rather than mixing one form's token with
    # another form's answers:
    #
    #   clickwrap_submission_params_from(
    #     response,
    #     form_css_selector: "form[action='/withdrawals/confirm']"
    #   )
    #
    # @param rendered [String, #body] the HTML, or the integration response
    # @param answers [Hash] statement key => true/false/String override
    # @param form_css_selector [String, nil] exact CSS selector for one form
    # @return [Hash] params ready to merge into the POST
    def clickwrap_submission_params_from(rendered, answers: {}, form_css_selector: nil)
      require "nokogiri"

      html = rendered.respond_to?(:body) ? rendered.body : rendered.to_s
      page = Nokogiri::HTML(html)
      scope = clickwrap_test_form_scope(page, form_css_selector)

      token_fields = scope.css('input[name="clickwrap_submission[presentation_token]"]')
      if token_fields.many?
        raise ArgumentError,
              "The rendered page carries #{token_fields.size} clickwrap presentation tokens. " \
              "Pass form_css_selector: with a CSS selector that matches exactly one form."
      end

      token = token_fields.first&.[]("value")
      if token.to_s.empty?
        raise ArgumentError,
              "The rendered page carries no clickwrap presentation token. GET the page that " \
              "renders `form.clickwrap` (or `form.clickwrap_fields`) first, then pass that " \
              "response to clickwrap_submission_params_from."
      end

      overrides = answers.transform_keys(&:to_s)
      controls_by_statement = scope.css(%([name^="clickwrap_submission[answers]["]))
                                   .group_by { |control| control["name"][/\[answers\]\[([^\]]+)\]/, 1] }

      answered = controls_by_statement.each_with_object({}) do |(key, controls), result|
        next if key.nil?

        answer = if overrides.key?(key)
                   normalize_rendered_control_answer(controls, overrides.fetch(key))
                 else
                   default_rendered_control_answer(controls)
                 end
        result[key] = answer unless answer.nil?
      end

      { "clickwrap_submission" => { "presentation_token" => token, "answers" => answered.compact } }
    end
    module_function :clickwrap_submission_params_from
    public :clickwrap_submission_params_from

    def clickwrap_test_form_scope(page, form_css_selector)
      return page if form_css_selector.nil?

      forms = page.css(form_css_selector.to_s)
      unless forms.one? && forms.first.name == "form"
        raise ArgumentError,
              "form_css_selector must match exactly one <form>; it matched #{forms.size}. " \
              "Received #{form_css_selector.inspect}."
      end

      forms.first
    rescue Nokogiri::CSS::SyntaxError => error
      raise ArgumentError,
            "form_css_selector must be valid CSS. #{error.message}"
    end
    module_function :clickwrap_test_form_scope
    private :clickwrap_test_form_scope

    # A checkbox's affirmative value is conventionally "1". A radio group's
    # value is the exact choice key the server offered — sometimes "yes", but
    # just as legitimately "employee", "contractor", or another domain word.
    # Reading the rendered value keeps this integration helper faithful to the
    # real form instead of fabricating a checkbox answer for every control.
    def default_rendered_control_answer(controls)
      first = controls.first
      first["type"] == "radio" ? first["value"].to_s : "1"
    end
    module_function :default_rendered_control_answer

    def normalize_rendered_control_answer(controls, value)
      return normalize_test_answer(value) unless controls.first["type"] == "radio"
      return nil if value.nil?
      return controls.first["value"].to_s if value == true

      if value == false
        negative = controls.find do |control|
          control["value"].to_s.in?(%w[no decline false 0])
        end
        return (negative || controls.last)["value"].to_s
      end

      value.to_s
    end
    module_function :normalize_rendered_control_answer
    private :default_rendered_control_answer, :normalize_rendered_control_answer

    def normalize_test_answer(value)
      case value
      when true then "1"
      when false then "0"
      when nil then nil
      else value.to_s
      end
    end
    module_function :normalize_test_answer
    private :normalize_test_answer

    # Presents, answers, and captures — the everyday way to get real evidence
    # into a test database.
    #
    # An empty `answers:` affirms every required statement and leaves every
    # optional one alone, which is what a person completing the form normally
    # does. Optional controls are never auto-answered: leaving one unselected
    # creates no grant, and a helper that quietly granted an optional consent
    # would hide exactly the bug that distinction exists to catch.
    #
    # @return [Clickwrap::Receipt]
    def capture_clickwrap(policy_key, actor:, answers: {}, subject: nil, tenant: nil, locale: nil,
                          capture_channel: :web_browser, http_request: nil, acting_for: nil)
      presentation = present_clickwrap(policy_key, actor: actor, subject: subject,
                                                   tenant: tenant, locale: locale,
                                                   acting_for: acting_for,
                                                   capture_channel: capture_channel)

      result = Clickwrap.capture!(
        policy_key,
        actor: actor,
        subject: subject,
        tenant: tenant,
        acting_for: acting_for,
        http_request: http_request,
        capture_channel: capture_channel,
        submission: submission_for(presentation, default_clickwrap_answers(policy_key, answers))
      )

      committed_test_receipt(result)
    end
    module_function :capture_clickwrap
    public :capture_clickwrap

    # The same, with a protected action in the same transaction. Use it to
    # prove that your domain write and its evidence commit together.
    #
    # @return [Clickwrap::Receipt]
    def capture_clickwrap_and(policy_key, actor:, answers: {}, subject: nil, tenant: nil,
                              capture_channel: :web_browser, http_request: nil, acting_for: nil, &)
      presentation = present_clickwrap(policy_key, actor: actor, subject: subject, tenant: tenant,
                                                   acting_for: acting_for,
                                                   capture_channel: capture_channel)

      result = Clickwrap.capture_and!(
        policy_key,
        actor: actor,
        subject: subject,
        tenant: tenant,
        acting_for: acting_for,
        http_request: http_request,
        capture_channel: capture_channel,
        submission: submission_for(presentation, default_clickwrap_answers(policy_key, answers)),
        &
      )

      committed_test_receipt(result)
    end
    module_function :capture_clickwrap_and
    public :capture_clickwrap_and

    # Transactional test wrappers intentionally never commit. The production
    # API therefore returns PendingReceipt inside them, correctly, while tests
    # still need to inspect the rows they just created. This test-only adapter
    # exposes a Receipt projection without changing the pending object's
    # `committed?` answer or weakening the production finality contract.
    def committed_test_receipt(result)
      return result unless result.is_a?(PendingReceipt)

      Receipt.new(result.event)
    end
    module_function :committed_test_receipt
    private :committed_test_receipt

    def reset_clickwrap_test_database!
      connection = ::ActiveRecord::Base.connection
      protected_tables = %w[ar_internal_metadata schema_migrations]
      tables = connection.tables - protected_tables

      connection.disable_referential_integrity do
        tables.each { |table| connection.execute("DELETE FROM #{connection.quote_table_name(table)}") }
      end
    end
    private :reset_clickwrap_test_database!

    # --- The harder cases -----------------------------------------------------

    # A presentation whose manifest has ALREADY EXPIRED.
    #
    # Built by taking a real presentation and rewriting its issue and expiry
    # times into the past, then signing it with the manifest verifier directly
    # rather than through `to_token`.
    #
    # That last part is the subtle bit and it is deliberate. `to_token` passes
    # the manifest's `expires_at` to the message verifier, so an
    # already-expired manifest produces a token the signature layer refuses
    # before Clickwrap's own expiry check ever runs — and the test would then
    # be asserting that `ActiveSupport::MessageVerifier` works. Signing without
    # the message-level TTL leaves a perfectly valid signature over a manifest
    # that is plainly out of date, so what rejects it is the server's own
    # `PresentationExpired` path. Real check, not a mocked one.
    #
    # @return [Clickwrap::Presenter::Result] whose token is expired
    def expired_clickwrap_presentation_for(policy_key, **)
      presentation = present_clickwrap(policy_key, **)
      window = Clickwrap.config.presentation_valid_for
      now = Clickwrap.now

      expired = PresentationManifest.new(
        presentation.manifest.to_h.merge(
          "issued_at" => Receipt.format_time(now - (window * 2)),
          "expires_at" => Receipt.format_time(now - window)
        )
      )

      presentation.with(manifest: expired, token: clickwrap_token_without_message_expiry(expired))
    end
    module_function :expired_clickwrap_presentation_for
    public :expired_clickwrap_presentation_for

    # A token bound to a policy revision that is no longer on file — the token
    # a browser holds when the policy was edited and redeployed between the GET
    # and the POST.
    #
    # The revision digest is replaced with a derived one rather than by
    # deleting the real PolicyRevision row, so the fixture other tests rely on
    # survives. Capture rejects it with `:stale_policy_revision`.
    #
    # @return [String] a signed presentation token
    def stale_clickwrap_token_for(policy_key, **)
      presentation = present_clickwrap(policy_key, **)
      attributes = presentation.manifest.to_h
      superseded = Digest.digest("superseded:#{attributes.dig("policy", "revision")}")

      PresentationManifest
        .new(attributes.merge("policy" => attributes["policy"].merge("revision" => superseded)))
        .to_token
    end
    module_function :stale_clickwrap_token_for
    public :stale_clickwrap_token_for

    # A token legitimately issued to somebody else, for the swapped-token case.
    # Submit it while capturing as `actor` and Capture rejects it with
    # `:presentation_actor_mismatch`.
    #
    # @return [String] a signed presentation token bound to `other_actor`
    def other_actors_clickwrap_token_for(policy_key, actor:, other_actor:)
      if Reference.actor(actor) == Reference.actor(other_actor)
        raise ArgumentError,
              "other_actors_clickwrap_token_for was given the same actor twice, so the token it " \
              "returned would be the actor's own and the mismatch it exists to trigger could " \
              "never happen. Pass two different records."
      end

      present_clickwrap(policy_key, actor: other_actor).token
    end
    module_function :other_actors_clickwrap_token_for
    public :other_actors_clickwrap_token_for

    # Submits the SAME presentation twice, which is what a double-click, a
    # retried request, and a replayed token all look like to the server.
    #
    # Returns both results. An identical repeat returns the original receipt
    # without running anything twice, so the two share an `event_id`; a repeat
    # with different answers raises `Clickwrap::ReplayRejected`.
    #
    # @return [Array<Clickwrap::Receipt>] the first and second results
    def submit_clickwrap_twice(policy_key, actor:, answers: {}, subject: nil, tenant: nil)
      presentation = present_clickwrap(policy_key, actor: actor, subject: subject, tenant: tenant)
      submission = submission_for(presentation, default_clickwrap_answers(policy_key, answers))

      options = { actor: actor, subject: subject, tenant: tenant,
                  capture_channel: "web_browser", submission: submission }

      [Clickwrap.capture!(policy_key, **options), Clickwrap.capture!(policy_key, **options)]
    end
    module_function :submit_clickwrap_twice
    public :submit_clickwrap_twice

    # --- System tests ---------------------------------------------------------

    # Checks every required control the policy declares, on the page currently
    # rendered, and leaves optional ones alone.
    #
    #   complete_clickwrap :signup
    #   click_button "Create account"
    #
    # Controls are found by their form-field name rather than by an id, so this
    # keeps working after you eject the views and restyle everything: the name
    # is part of the submission contract, the markup around it is yours.
    def complete_clickwrap(policy_key)
      unless respond_to?(:page)
        raise NoMethodError,
              "complete_clickwrap drives a rendered page and needs Capybara, so it works in a " \
              "system test. In a model or integration test use capture_clickwrap, which goes " \
              "through the same presenter and capture path without a browser."
      end

      Clickwrap.policy!(policy_key).statements.reject(&:optional?).each do |statement|
        complete_clickwrap_statement(statement)
      end
    end

    # --- Assertions -----------------------------------------------------------

    # Assert that an actor currently satisfies a whole policy.
    def assert_clickwrap_current(policy_key, actor:, subject: nil, tenant: nil)
      result = Clickwrap.verify(policy_key, actor: actor, subject: subject, tenant: tenant)

      assert result.success?,
             "Expected #{clickwrap_actor_label(actor)} to currently satisfy the #{policy_key} " \
             "policy, but verification failed with #{result.error.inspect}: #{result.message}. " \
             "#{clickwrap_state_summary(actor, policy_key)}"
    end

    # Assert that an actor does NOT currently satisfy a policy.
    def refute_clickwrap_current(policy_key, actor:, subject: nil, tenant: nil)
      result = Clickwrap.verify(policy_key, actor: actor, subject: subject, tenant: tenant)

      refute result.success?,
             "Expected #{clickwrap_actor_label(actor)} NOT to satisfy the #{policy_key} policy, " \
             "but verification succeeded against event #{result.event_id}. " \
             "#{clickwrap_state_summary(actor, policy_key)}"
    end

    def assert_clickwrap_agreed_to(statement_key, actor:, subject: nil, tenant: nil)
      assert_clickwrap_kind("agreement", :agreed_to?, statement_key, actor, subject, tenant)
    end

    def assert_clickwrap_acknowledged(statement_key, actor:, subject: nil, tenant: nil)
      assert_clickwrap_kind("acknowledgment", :acknowledged?, statement_key, actor, subject, tenant)
    end

    def assert_clickwrap_consented_to(purpose_key, actor:, subject: nil, tenant: nil)
      assert_clickwrap_kind("consent", :consented_to?, purpose_key, actor, subject, tenant)
    end

    def assert_clickwrap_declared(statement_key, actor:, subject: nil, tenant: nil)
      assert_clickwrap_kind("declaration", :declared?, statement_key, actor, subject, tenant)
    end

    def assert_clickwrap_authorized(statement_key, actor:, subject: nil, tenant: nil)
      assert_clickwrap_kind("authorization", :authorized?, statement_key, actor, subject, tenant)
    end

    # Assert that an actor is exempted from a policy — a deliberately separate
    # question from having agreed to it. An exemption records that no human
    # action occurred, so it can never satisfy `assert_clickwrap_agreed_to`,
    # and a test that expects it to has found a real bug rather than a helper
    # limitation.
    def assert_clickwrap_exempted_from(policy_key, actor:, subject: nil, tenant: nil)
      proxy = ActorProxy.new(actor)

      assert proxy.exempted_from?(policy_key, subject: subject, tenant: tenant),
             "Expected #{clickwrap_actor_label(actor)} to be exempted from #{policy_key}, but no " \
             "exemption event was recorded for them. An exemption is created explicitly with " \
             "Clickwrap.exempt!(#{policy_key.to_sym.inspect}, actor:, because:), and the policy " \
             "must permit one. #{clickwrap_state_summary(actor, policy_key)}"
    end

    # Assert that a receipt still verifies: its digest covers its bytes, its
    # document versions still match what was published, and the event has not
    # been disposed of.
    def assert_clickwrap_receipt_verifies(receipt)
      result = receipt.verify

      assert result.success?,
             "Expected receipt #{receipt.event_id} to verify, but it failed with " \
             "#{result.error.inspect}: #{result.message}. A digest failure means the event row's " \
             "meaningful bytes changed after it was written; a document failure means a " \
             "published version was edited in place instead of republished under a new label."
    end

    # Assert that no event exists for a policy — the other half of a fault
    # injection test, where the point is that nothing was recorded.
    def assert_no_clickwrap_event(policy_key, actor: nil)
      scope = Event.for_policy(policy_key)
      scope = scope.for_actor(Reference.actor(actor)) if actor
      found = scope.chronological.to_a
      listed = found.join("; ")
      whose = actor ? " and #{clickwrap_actor_label(actor)}" : ""

      assert found.empty?,
             "Expected no Clickwrap event for #{policy_key}#{whose}, but found " \
             "#{found.length}: #{listed}. If this followed a fault injection block, the evidence " \
             "write was not rolled back with the action it was supposed to commit alongside."
    end

    private

    # Required statements get an affirmative answer; optional ones are left
    # untouched. Anything the caller passed wins over both.
    # Explicit beats implicit, and the rule is deliberately all-or-nothing.
    #
    # `answers: {}` affirms every required statement, which is what a person
    # completing the form normally does and what most tests want. But the moment
    # a test names ANY answer, it gets exactly what it named and nothing else —
    # because the tests that matter most here are the ones that deliberately
    # leave a required statement unanswered, and a helper that quietly filled it
    # in would turn "the server refuses an incomplete submission" into a test
    # that passes for the wrong reason.
    def default_clickwrap_answers(policy_key, answers)
      return answers.transform_keys(&:to_s) if answers.present?

      Clickwrap.policy!(policy_key).required_statements.to_h do |statement|
        [statement.key, statement.choices ? clickwrap_granting_choice(statement) : "1"]
      end
    end
    module_function :default_clickwrap_answers

    # The choice a policy declared as meaning "grant"; otherwise the first one
    # offered, so a statement with domain-specific choice names still works.
    def clickwrap_granting_choice(statement)
      statement.choices.find { |_, meaning| meaning == "grant" }&.first || statement.choices.keys.first
    end
    module_function :clickwrap_granting_choice

    def clickwrap_token_without_message_expiry(manifest)
      PresentationManifest.verifier.generate(
        manifest.to_h, purpose: PresentationManifest::SIGNING_PURPOSE
      )
    end
    module_function :clickwrap_token_without_message_expiry

    def assert_clickwrap_kind(kind, predicate, statement_key, actor, subject, tenant)
      satisfied = ActorProxy.new(actor).public_send(predicate, statement_key,
                                                    subject: subject, tenant: tenant)

      assert satisfied,
             "Expected #{clickwrap_actor_label(actor)} to have a current #{kind} for " \
             "#{statement_key.inspect}, and they do not. Remember that an exemption never " \
             "satisfies a human-action question, an optional control left unselected creates no " \
             "grant, and a withdrawn, expired, superseded, or consumed record is recorded but " \
             "not current. #{clickwrap_statement_summary(actor, statement_key)}"
    end

    def clickwrap_actor_label(actor)
      return "(no actor)" if actor.nil?

      Reference.actor(actor)
    rescue StandardError
      actor.inspect
    end

    def clickwrap_state_summary(actor, policy_key)
      states = StatementState
               .for_actor(clickwrap_actor_label(actor))
               .for_policy(policy_key)
               .map { |state| "#{state.statement_key}=#{state.state}" }

      return "No statement states are recorded for them under #{policy_key}." if states.empty?

      "Recorded states: #{states.join(", ")}."
    end

    def clickwrap_statement_summary(actor, statement_key)
      states = StatementState
               .for_actor(clickwrap_actor_label(actor))
               .for_statement(statement_key)
               .map { |state| "#{state.kind} #{state.state} (expires #{state.expires_at || "never"})" }

      return "Nothing is recorded for #{statement_key.inspect} at all." if states.empty?

      "Recorded: #{states.join("; ")}."
    end

    def complete_clickwrap_statement(statement)
      name = "clickwrap_submission[answers][#{statement.key}]"

      if statement.choices
        value = clickwrap_granting_choice(statement)
        page.find(:css, "input[name='#{name}'][value='#{value}']", visible: :all).set(true)
      else
        page.find(:css, "input[type='checkbox'][name='#{name}']", visible: :all).set(true)
      end
    end
  end
end
