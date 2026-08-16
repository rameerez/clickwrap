# frozen_string_literal: true

require "rails/engine"

module Clickwrap
  # The mountable engine: wires autoloading, migrations, locales, the
  # ActiveRecord macro, the form-builder extension, the controller helpers, and
  # boot-time policy loading into the host app.
  class Engine < ::Rails::Engine
    isolate_namespace Clickwrap

    # -------------------------------------------------------------------------
    # Zeitwerk: the gem keeps its ActiveRecord models under lib/clickwrap/models
    # (same layout as the moderate and chats gems) so the whole domain ships in
    # lib/ and the engine's app/ tree only holds the web layer. For that to
    # autoload correctly we manage the loader by hand:
    #
    #   - `push_dir(lib/clickwrap, namespace: Clickwrap)` makes
    #     lib/clickwrap/models/... autoloadable *under the Clickwrap namespace*.
    #   - `collapse(models)` + `collapse(models/concerns)` mean the files in
    #     those folders define Clickwrap::Event / Clickwrap::HasClickwraps —
    #     not Clickwrap::Models::Event.
    #   - The SPINE files are required explicitly by lib/clickwrap.rb at boot,
    #     so they must be *ignored* by the loader or Zeitwerk would complain
    #     about double definitions.
    # -------------------------------------------------------------------------
    LIB_ROOT = File.expand_path("..", __dir__)
    CLICKWRAP_LIB = File.expand_path("clickwrap", LIB_ROOT)

    ZEITWERK_IGNORED = %w[
      version.rb
      errors.rb
      vocabulary.rb
      canonical_json.rb
      digest.rb
      identifier.rb
      configuration.rb
      engine.rb
      macros.rb
      registry.rb
      localized_text.rb
      document_definition.rb
      statement.rb
      request_evidence_policy.rb
      policy.rb
      retention_class.rb
      dsl/policy_builder.rb
      dsl/retention_builder.rb
      document_renderers/markdown.rb
      form_builder_extensions.rb
      view_helpers.rb
      controller_helpers.rb
      registration.rb
    ].freeze

    initializer "clickwrap.autoload", before: :set_autoload_paths do
      loader = Rails.autoloaders.main

      ZEITWERK_IGNORED.each do |file|
        path = File.join(CLICKWRAP_LIB, file)
        loader.ignore(path) if File.exist?(path)
      end

      %w[models models/concerns].each do |dir|
        path = File.join(CLICKWRAP_LIB, dir)
        loader.collapse(path) if File.directory?(path)
      end

      loader.push_dir(CLICKWRAP_LIB, namespace: Clickwrap)
    end

    config.eager_load_paths << CLICKWRAP_LIB

    # Make the gem's migrations runnable from the host without copying
    # (`rails db:migrate` picks them up). The install generator still copies a
    # host-owned migration, which is the recommended path: a released migration
    # is never edited underneath an installed application, so the host owns the
    # file that describes its own schema.
    initializer "clickwrap.migrations" do |app|
      unless app.root.to_s == root.to_s
        config.paths["db/migrate"].expanded.each do |path|
          app.config.paths["db/migrate"] << path
        end
      end
    end

    # Expose `has_clickwraps` on every AR model.
    initializer "clickwrap.active_record" do
      ActiveSupport.on_load(:active_record) do
        extend Clickwrap::Macros
      end
    end

    # Expose `form.clickwrap` and `form.clickwrap_fields` on the standard form
    # builder, so the one-line happy path works in an ordinary `form_with`.
    initializer "clickwrap.form_builder" do
      ActiveSupport.on_load(:action_view) do
        ActionView::Helpers::FormBuilder.include(Clickwrap::FormBuilderExtensions)
        # The custom-surface helpers (token field, statement controls, the
        # manifest-worded submit) — available in every view, like the form
        # builder methods above.
        include Clickwrap::ViewHelpers
      end
    end

    # Give host controllers `clickwrap_submission`, `capture_clickwrap_and!`,
    # and the `requires_clickwrap` gate.
    initializer "clickwrap.action_controller" do
      ActiveSupport.on_load(:action_controller) do
        include Clickwrap::ControllerHelpers

        # `clickwraps_registration_with :signup` for Devise controllers. The
        # macro is available everywhere; nothing happens unless a controller
        # actually calls it, and Devise is never required.
        include Clickwrap::Registration
      end
    end

    # Ship the gem's locale files. Host locale files with the same keys override
    # these automatically (I18n's load order puts the app last), which is how a
    # host rewords a statement without forking a view.
    initializer "clickwrap.locales" do |app|
      app.config.i18n.load_path += Dir[root.join("config", "locales", "**", "*.{rb,yml}").to_s]
    end

    initializer "clickwrap.assets" do |app|
      app.config.assets.paths << root.join("app/assets/stylesheets") if app.config.respond_to?(:assets)
    end

    # Load the host's document, policy, and retention declarations. They live in
    # ordinary Ruby files so they are reviewable in a diff and deployable like
    # code; `to_prepare` re-reads them on every boot and every development
    # reload, and compilation raises on a mistake rather than deferring it to
    # the first person who tries to sign up.
    # Every `requires_clickwrap` gate, checked once the host's routes exist.
    #
    # `after_routes_loaded` rather than `after_initialize`, and the difference
    # matters: `after_initialize` runs while the application is still
    # initializing, which is precisely when the routes reloader declines to
    # load. Checking there would report "the engine is not mounted" to
    # applications that mount it perfectly well, which is worse than not
    # checking at all. This hook fires at the one moment the answer is knowable.
    #
    # A dead-end gate is still better found at boot than by the first person it
    # stops, so the request path keeps its own backstop for controllers that are
    # autoloaded later in development.
    if config.respond_to?(:after_routes_loaded)
      config.after_routes_loaded do
        Clickwrap::ControllerHelpers.verify_registered_gates!
        Clickwrap::Services::ValidatePolicyReferences.validate_remediation_paths!
      end
    end

    config.to_prepare do
      Clickwrap::Services::LoadPolicies.new.call

      # Whether the raw request-evidence values are encrypted is a host decision
      # read from the initializer, so it can only be applied once that has been
      # read — and it has to be re-applied on every development reload, because
      # the model class is a fresh object each time.
      Clickwrap::RequestEvidence.apply_configured_encryption!
    end
  end
end
