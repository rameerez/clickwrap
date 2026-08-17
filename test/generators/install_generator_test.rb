# frozen_string_literal: true

require "test_helper"
require "rails/generators/test_case"
require "generators/clickwrap/install_generator"
require "minitest/mock"
require "open3"
require "rbconfig"
require "tmpdir"

# `rails generate clickwrap:install` is the first thing anyone runs, and almost
# everything it writes is a decision with consequences years later: the schema
# evidence is stored under, and an initializer whose defaults decide what
# personal data this application starts collecting about people.
#
# Every run below passes `--skip-questions` or the privacy-minimized recipe,
# because the interactive path reads from $stdin and a test suite has no keyboard.
class InstallGeneratorTest < Rails::Generators::TestCase
  tests Clickwrap::Generators::InstallGenerator
  # Each test process needs its own destination. A fixed checkout-relative path
  # lets concurrent Ruby/Rails matrix lanes erase one another's generated
  # migration between generation and the scratch-database execution check.
  destination Dir.mktmpdir("clickwrap-generator-install-")
  setup :prepare_destination

  teardown do
    FileUtils.rm_rf(destination_root)
  end

  # Every request-evidence setting the initializer is supposed to write, in the
  # order the template writes them. Named here rather than derived from the
  # template so a setting silently disappearing from the template fails.
  RECORD_SETTINGS = [
    "record_ip_address_by_default",
    "record_browser_user_agent_by_default",
    *Clickwrap::Vocabulary::IP_GEOLOCATION_DATA_FIELDS.map { |field| "record_ip_geolocation_#{field}_by_default" }
  ].freeze

  # Words that would turn a scaffolding convenience into a runtime mode switch.
  # None of them may appear as a setting in a file this generator writes.
  FORBIDDEN_MODE_SETTINGS = %w[
    gdpr_compliant_mode maximum_evidence full_evidence legal_proof record_network_context
  ].freeze

  # A signed server manifest cannot prove that a browser rendered pixels or a
  # person perceived them. These phrases are narrower than the global legal-
  # claim vocabulary and specifically protect the files the installer writes.
  PRESENTATION_OVERCLAIMS = [
    "what was on screen",
    "actually shown",
    "actually presented",
    "wording that appeared beside"
  ].freeze

  test "installing writes the migration, the initializer, the policy file, and the legal placeholders" do
    run_generator %w[--skip-questions]

    assert_migration "db/migrate/create_clickwrap_tables.rb", /create_table :clickwrap_events/
    assert_file "config/initializers/clickwrap.rb", /Clickwrap\.configure do \|config\|/
    assert_file "config/clickwrap.rb", /Clickwrap\.policy :signup do/
    assert_file "config/clickwrap.rb", /Clickwrap\.retention :ordinary_agreement_evidence do/

    # Placeholders, never legal text. Both say so in their own first lines.
    assert_file "app/content/legal/terms.md", /PLACEHOLDER/
    assert_file "app/content/legal/privacy.md", /PLACEHOLDER/
  end

  test "the placeholders name their own version in front matter, and the declarations carry none" do
    run_generator %w[--skip-questions]

    # The version label belongs in the file that holds the words. A label kept
    # in a second place is a label that drifts, and a drifted label means the
    # bytes people accepted and the version the receipt names stop agreeing.
    {
      "app/content/legal/terms.md" => "Terms of Service",
      "app/content/legal/privacy.md" => "Privacy Notice"
    }.each do |path, title|
      assert_file path do |placeholder|
        assert_match(/\A---\n/, placeholder, "#{path} must open with the front-matter block")
        assert_match(/^title: #{title}$/, placeholder)
        assert_match(/^last_updated: #{Date.today.iso8601}$/, placeholder)
        assert_equal Date.today.iso8601, Clickwrap::FrontMatter.version_label_in(placeholder),
                     "#{path} must resolve the version label Clickwrap will read at boot"
      end
    end

    assert_file "config/clickwrap.rb" do |config|
      assert_no_version_declarations config
      assert_match(/front matter/, config,
                   "the generated file has to explain where the version label now lives")
    end
  end

  test "a run with no terminal skips the questions and says so, instead of jumbling prompts" do
    # Piped installs are how CI, provisioning scripts, and AI agents run this
    # generator. Streaming interactive prompts into a pipe would interleave
    # them with file output and silently take every [y/N] default anyway —
    # so the generator must skip deliberately and announce the posture it took.
    output = $stdin.stub(:tty?, false) do
      run_generator
    end

    assert_match(/Non-interactive run detected/, output)
    assert_match(/same as --skip-questions/, output)

    assert_file "config/initializers/clickwrap.rb" do |initializer|
      RECORD_SETTINGS.each do |setting|
        assert_match(/^\s*config\.#{setting} = false$/, initializer,
                     "A non-interactive run must write the collect-nothing default for #{setting}")
      end
    end
  end

  test "existing Sitepress legal pages become the document source and no second copy is written" do
    # An app that already serves its legal text (app/content/pages/legal, the
    # Sitepress convention) must not get a SECOND set of legal files: what
    # people accept has to be the same bytes the public legal routes render,
    # and two copies is how they silently stop being the same document.
    write_sitepress_legal_pages

    output = run_generator %w[--skip-questions]

    assert_match(%r{existing legal pages in app/content/pages/legal}, output)
    assert_match(/the gem points at your existing pages/, output)
    refute_match(/the gem wrote placeholders/, output,
                 "the review checklist must not claim placeholders that were never written")

    assert_file "config/clickwrap.rb" do |config|
      assert_match(%r{from: Rails\.root\.join\("app/content/pages/legal/terms\.html\.md"\)}, config)
      assert_match(%r{from: Rails\.root\.join\("app/content/pages/legal/privacy\.html\.md"\)}, config)

      # Both pages carry `last_updated:`, so each names its own version and the
      # declaration says nothing about labels. One file, one label, nothing to
      # drift apart the next time somebody edits the Terms in a hurry.
      assert_no_version_declarations config
    end

    assert_no_file "app/content/legal/terms.md"
    assert_no_file "app/content/legal/privacy.md"
  end

  test "a detected page with no version key keeps an explicit label and says where it belongs" do
    # A versionless declaration over a page whose front matter names no version
    # is a boot failure on the host's very next deploy. The generated file has
    # to boot, so the label is written here — and the one line that says where
    # it really belongs is written with it.
    write_sitepress_legal_pages(privacy_names_its_own_version: false)

    output = run_generator %w[--skip-questions]

    assert_file "config/clickwrap.rb" do |config|
      terms, privacy = document_declarations_in(config)

      refute_match(/version:/, terms, "terms.html.md names its own version and needs no label here")
      assert_match(/^\s+version: "#{Date.today.iso8601}",$/, privacy)
      assert_match(/Move this label into the page's own/, config)
      assert_match(/`last_updated:` front matter and delete the line/, config)
    end

    assert_match(/privacy\.html\.md/, output)
    assert_match(/no `clickwrap_version:` or `last_updated:` front-matter key/, output)
    assert_match(/Move that label into the page's own front matter/, output)
  end

  test "the front-matter warning names only the page that actually lacks a version key" do
    write_sitepress_legal_pages(privacy_names_its_own_version: false)

    output = run_generator %w[--skip-questions]

    # Naming both pages would send a developer looking for a problem that is not
    # in terms.html.md, which already names its own version.
    assert_equal "app/content/pages/legal/privacy.html.md", output[/⚠️ +(app\S+)/, 1]
  end

  test "one existing legal page is not treated as a convention — placeholders still cover both" do
    # Detection requires BOTH documents: pointing terms at an existing page
    # while privacy points at a placeholder would split the pair across two
    # directories and make the checklist half-wrong in each direction.
    FileUtils.mkdir_p(File.join(destination_root, "app/content/pages/legal"))
    File.write(File.join(destination_root, "app/content/pages/legal/terms.html.md"), "# Existing terms\n")

    run_generator %w[--skip-questions]

    assert_file "config/clickwrap.rb" do |config|
      assert_match(%r{from: Rails\.root\.join\("app/content/legal/terms\.md"\)}, config)
      assert_match(%r{from: Rails\.root\.join\("app/content/legal/privacy\.md"\)}, config)
    end

    assert_file "app/content/legal/terms.md", /PLACEHOLDER/
    assert_file "app/content/legal/privacy.md", /PLACEHOLDER/
  end

  test "installing twice does not write the migration a second time" do
    run_generator %w[--skip-questions]
    run_generator %w[--skip-questions]

    # Two CreateClickwrapTables migrations in one application is not a cosmetic
    # duplicate: the second one fails at `db:migrate` on a table that exists.
    assert_equal 1, Dir.glob(File.join(destination_root, "db/migrate/*_create_clickwrap_tables.rb")).length
  end

  test "the migration adapts its key types, JSON columns, and long-text columns to the host database" do
    run_generator %w[--skip-questions]

    assert_migration "db/migrate/create_clickwrap_tables.rb" do |migration|
      # uuid-vs-bigint follows the host's own generator setting, so clickwrap
      # tables can be embedded in a uuid app's polymorphic associations.
      assert_match(/primary_key_type, foreign_key_type = primary_and_foreign_key_types/, migration)
      assert_match(/config\.options\[config\.orm\]\[:primary_key_type\]/, migration)

      # Event chronology is a private numeric database sequence even in an app
      # whose ordinary model ids are UUIDs. The event's public id remains a
      # ULID; allowing this table to inherit `primary_key_type` would leave a
      # UUID primary key behind a bigint foreign key and fail at migration time.
      assert_match(/create_table :clickwrap_recording_sequences, id: :primary_key/, migration)
      assert_match(/t\.bigint :recording_sequence, null: false/, migration)

      # Column types resolve at MIGRATION RUN time, so one file works across the
      # dev/prod database split as well as across the CI matrix.
      assert_match(%r{return :jsonb if connection\.adapter_name\.downcase\.match\?\(/postg/\)}, migration)
      assert_match(/def json_column_type/, migration)

      # MySQL 8 refuses a default on a JSON column, so the default itself is a
      # branch rather than a literal.
      assert_match(/def json_column_default/, migration)
      assert_match(/def json_array_default/, migration)
      assert_match(%r{return nil if connection\.adapter_name\.downcase\.match\?\(/mysql\|trilogy/\)}, migration)

      # A silently truncated agreement is the worst failure this gem has, so
      # document bodies get MEDIUMTEXT on MySQL and ordinary TEXT elsewhere.
      assert_match(%r{return :mediumtext if connection\.adapter_name\.downcase\.match\?\(/mysql\|trilogy/\)}, migration)
      assert_match(/t\.send\(text_column_type, :content\)/, migration)
    end
  end

  test "the initializer writes every request-evidence setting, and every one of them is off" do
    run_generator %w[--skip-questions]

    assert_file "config/initializers/clickwrap.rb" do |initializer|
      RECORD_SETTINGS.each do |setting|
        # Off is the safe default and it has to be WRITTEN rather than implied:
        # a setting that is absent from the file is a setting nobody reviews.
        assert_match(/^\s*config\.#{setting} = false$/, initializer,
                     "Expected config.#{setting} to be written and set to false")
      end

      # Nothing is enabled, so there is nothing to justify, delete, or resolve.
      assert_match(/config\.reason_for_recording_ip_addresses_by_default = nil/, initializer)
      assert_match(/config\.delete_recorded_ip_addresses_after = nil/, initializer)
      assert_match(/config\.ip_geolocation_resolver = nil/, initializer)
      assert_match(/config\.review_default_request_evidence_configuration_on = nil/, initializer)
    end
  end

  test "an app that renders its own legal pages through markdown-rails publishes through it too" do
    # Both halves have to be true: the application renders these exact pages,
    # and it bundles the renderer they go through. Then the snapshot people
    # accept and the page they read come out of one pipeline instead of two
    # that somebody has to keep in agreement by hand.
    write_sitepress_legal_pages
    write_gemfile_lock_bundling("markdown-rails")

    run_generator %w[--skip-questions]

    assert_file "config/initializers/clickwrap.rb" do |initializer|
      assert_match(/^\s*config\.document_renderer = :markdown_rails$/, initializer)
      assert_match(/byte-identical to the page they/, initializer)
    end
  end

  test "markdown-rails in the bundle alone does not choose a renderer for pages the app does not serve" do
    # The placeholders this installer writes are not pages the application
    # renders, so there is nothing to be byte-identical WITH.
    write_gemfile_lock_bundling("markdown-rails")

    run_generator %w[--skip-questions]

    assert_file "config/initializers/clickwrap.rb", /^\s*config\.document_renderer = nil$/
  end

  test "detected pages without markdown-rails keep the faithful default and name the built-in options" do
    write_sitepress_legal_pages
    write_gemfile_lock_bundling("kramdown")

    run_generator %w[--skip-questions]

    assert_file "config/initializers/clickwrap.rb" do |initializer|
      assert_match(/^\s*config\.document_renderer = nil$/, initializer)
      assert_match(/`:markdown` renders HTML/, initializer)
      assert_match(/`:markdown_rails` renders through your/, initializer)
    end
  end

  test "the initializer publishes on db:prepare and says what that removes" do
    output = run_generator %w[--skip-questions]

    assert_file "config/initializers/clickwrap.rb" do |initializer|
      assert_match(/^\s*config\.publish_documents_after_database_preparation = true$/, initializer)
      assert_match(/rides `db:prepare`/, initializer)
      assert_match(%r{`bin/rails clickwrap:publish`}, initializer)
    end

    # The manual step is still printed, because the first publish happens
    # locally long before anything is deployed.
    assert_match(%r{bin/rails clickwrap:publish}, output)
    assert_match(/publishing rides `db:prepare`/, output)
  end

  test "the installer never generates an authentication description that claims a session nobody had" do
    run_generator %w[--skip-questions]

    assert_file "config/initializers/clickwrap.rb" do |initializer|
      # A signup form has no signed-in actor, and a generated lambda that
      # unconditionally reported `:authenticated_session` would put that claim
      # into every signup receipt. The built-in default answers correctly on its
      # own, so the generated file documents it rather than overriding it.
      refute_match(/^\s*config\.describe_authentication_with\s*=/, initializer)
      assert_match(/^\s*#\s*config\.describe_authentication_with = lambda do \|_controller\|$/, initializer)
      assert_match(/only when it gets one/, initializer)
    end
  end

  test "the initializer offers the Hotwire Native seam without turning it on" do
    run_generator %w[--skip-questions]

    assert_file "config/initializers/clickwrap.rb" do |initializer|
      refute_match(/^\s*config\.hotwire_native_document_links\s*=/, initializer)
      assert_match(/^\s*#\s*config\.hotwire_native_document_links = \{$/, initializer)
      assert_match(/pops the sheet/, initializer)
      assert_match(/open_in: :external_browser/, initializer)
    end
  end

  test "the review checklist asks for the stylesheet the rendered blocks need" do
    output = run_generator %w[--skip-questions]

    assert_match(/stylesheet_link_tag "clickwrap"/, output)
    assert_match(/scoped under/, output)
  end

  test "the privacy-minimized recipe writes explicit off settings and leaves no runtime switch behind" do
    run_generator %w[--request-evidence-recipe=privacy-minimized]

    assert_file "config/initializers/clickwrap.rb" do |initializer|
      RECORD_SETTINGS.each do |setting|
        assert_match(/^\s*config\.#{setting} = false$/, initializer,
                     "Expected privacy-minimized to write config.#{setting} = false")
      end

      # The flag is scaffolding. It expands into ordinary settings and then
      # stops existing. Nothing here may read as a runtime mode.
      FORBIDDEN_MODE_SETTINGS.each do |name|
        refute_match(/^\s*config\.[\w.]*#{name}/, initializer,
                     "#{name} must never exist as a runtime setting — a flag cannot make a legal determination")
      end
      refute_match(/^\s*config\.[\w.]*recipe/, initializer,
                   "the recipe is generator-only and must not survive into the configuration")
      refute_match(/config\.identify_actor_with\s*=.*to_gid/, initializer,
                   "a generated initializer must still work when a minimal Rails host does not load GlobalID")
    end
  end

  test "the installer refuses the removed evidence-rich shortcut before writing files" do
    stderr = capture(:stderr) do
      run_generator %w[--request-evidence-recipe=evidence-rich]
    end

    assert_match(/request-evidence-recipe.*privacy-minimized/i, stderr)
    assert_no_file "config/initializers/clickwrap.rb"
    assert_empty Dir.glob(File.join(destination_root, "db/migrate/*_create_clickwrap_tables.rb"))
  end

  test "asking for IP addresses on the command line turns on that one setting and nothing else" do
    proxy_digest = Clickwrap::Digest.digest("reviewed proxy configuration")
    run_generator [
      "--skip-questions",
      "--record-ip-addresses-by-default",
      "--reason-for-recording-ip-addresses-by-default=Investigate disputed agreement submissions.",
      "--delete-recorded-ip-addresses-after-days=90",
      "--trusted-proxy-configuration-digest=#{proxy_digest}"
    ]

    assert_file "config/initializers/clickwrap.rb" do |initializer|
      assert_match(/^\s*config\.record_ip_address_by_default = true$/, initializer)

      # Nothing rides along. A field that switches on as a side effect of another
      # field is exactly the failure this gem exists not to have.
      (RECORD_SETTINGS - ["record_ip_address_by_default"]).each do |setting|
        assert_match(/^\s*config\.#{setting} = false$/, initializer,
                     "Enabling IP addresses must not enable #{setting}")
      end

      reason_setting = /config\.reason_for_recording_ip_addresses_by_default =\s*\n?\s*/
      assert_match(reason_setting, initializer)
      assert_match(/"Investigate disputed agreement submissions\."/, initializer)
      assert_match(/config\.delete_recorded_ip_addresses_after = 90\.days/, initializer)
      assert_match(
        /config\.trusted_proxy_configuration_digest\s*=\s*#{Regexp.escape(proxy_digest.inspect)}/,
        initializer
      )
      assert_match(/config\.reason_for_recording_browser_user_agents_by_default = nil/, initializer)
      assert_match(/config\.ip_geolocation_resolver = nil/, initializer)
    end
  end

  test "IP evidence derives proxy provenance from Rails when no digest override is supplied" do
    run_generator [
      "--skip-questions",
      "--record-ip-addresses-by-default",
      "--reason-for-recording-ip-addresses-by-default=Investigate disputed agreement submissions.",
      "--delete-recorded-ip-addresses-after-days=90"
    ]

    assert_file "config/initializers/clickwrap.rb" do |initializer|
      assert_match(/Clickwrap\.trusted_proxy_configuration_digest_for_rails_application/, initializer)
      refute_match(/digest of a sentence/i, initializer)
    end
  end

  test "an incomplete enabled category is refused before any file is written" do
    stderr = capture(:stderr) do
      run_generator %w[--skip-questions --record-ip-addresses-by-default]
    end

    assert_match(/cannot enable IP addresses with a blank or scaffolding reason/i, stderr)
    assert_match(/No files were written/, stderr)
    assert_no_file "config/initializers/clickwrap.rb"
    assert_empty Dir.glob(File.join(destination_root, "db/migrate/*_create_clickwrap_tables.rb"))
  end

  test "IP geolocation requires explicit uncertainty and a resolver class" do
    common = [
      "--skip-questions",
      "--record-ip-geolocation-latitude-and-longitude-by-default",
      "--reason-for-recording-ip-geolocation-by-default=Investigate the network context of disputed submissions.",
      "--delete-recorded-ip-geolocation-after-days=30"
    ]

    stderr = capture(:stderr) { run_generator common }
    assert_match(/without their accuracy radius/i, stderr)
    assert_no_file "config/initializers/clickwrap.rb"

    proxy_digest = Clickwrap::Digest.digest("reviewed proxy configuration")
    run_generator common + [
      "--record-ip-geolocation-accuracy-radius-in-kilometers-by-default",
      "--trusted-proxy-configuration-digest=#{proxy_digest}",
      "--ip-geolocation-resolver-class-name=Clickwrap::IpGeolocation::TrackdownResolver"
    ]

    assert_file "config/initializers/clickwrap.rb" do |initializer|
      assert_match(/config\.record_ip_geolocation_latitude_and_longitude_by_default = true/, initializer)
      assert_match(/config\.record_ip_geolocation_accuracy_radius_in_kilometers_by_default = true/, initializer)
      assert_match(
        /config\.trusted_proxy_configuration_digest\s*=\s*#{Regexp.escape(proxy_digest.inspect)}/,
        initializer
      )
      assert_match(/config\.ip_geolocation_resolver = Clickwrap::IpGeolocation::TrackdownResolver\.new/, initializer)
    end
  end

  test "nothing the installer writes or prints claims what this gem cannot claim" do
    output = run_generator %w[--skip-questions]

    generated = Dir.glob(File.join(destination_root, "**/*")).select { |path| File.file?(path) }
    assert_operator generated.length, :>, 0, "the generator wrote nothing, so this proves nothing"

    ([output] + generated.map { |path| File.read(path) }).each do |body|
      Clickwrap::Vocabulary::PROHIBITED_CLAIM_PHRASES.each do |phrase|
        refute_includes body.downcase, phrase,
                        "Generated output claims #{phrase.inspect}, which no library can honestly claim"
      end
      PRESENTATION_OVERCLAIMS.each do |phrase|
        refute_includes body.downcase, phrase,
                        "Generated output claims human perception with #{phrase.inspect}"
      end
    end
  end

  # --- The drift test ---------------------------------------------------------
  #
  # The dummy app migrates a CONCRETE COPY of the ERB template on every CI
  # database leg (sqlite / postgres / mysql). These three tests fail the build the
  # moment the template and that copy disagree, so "the migration the dummy
  # proved" and "the migration users actually get" can never diverge silently —
  # which would mean the whole suite is green against a schema nobody ships.

  TEMPLATE_MIGRATION = File.expand_path(
    "../../lib/generators/clickwrap/templates/create_clickwrap_tables.rb.erb", __dir__
  )
  DUMMY_MIGRATION = File.expand_path(
    "../dummy/db/migrate/20260101000001_create_clickwrap_tables.rb", __dir__
  )

  test "the dummy's clickwrap migration declares the same columns as the template" do
    assert_equal column_names_in(TEMPLATE_MIGRATION), column_names_in(DUMMY_MIGRATION)
  end

  test "the dummy's clickwrap migration declares the same tables as the template" do
    assert_equal table_names_in(TEMPLATE_MIGRATION), table_names_in(DUMMY_MIGRATION)
  end

  test "the dummy's clickwrap migration declares the same indexes as the template" do
    # The unique indexes here are load-bearing behavior, not tuning: they are
    # what make a duplicate submit lose an INSERT race instead of producing two
    # live authorizations.
    assert_equal index_names_in(TEMPLATE_MIGRATION), index_names_in(DUMMY_MIGRATION)
  end

  test "the dummy's clickwrap migration declares the same foreign keys as the template" do
    assert_equal foreign_keys_in(TEMPLATE_MIGRATION), foreign_keys_in(DUMMY_MIGRATION)
  end

  test "the dummy migration is an ordered, exact rendering of the install template" do
    template = migration_body(TEMPLATE_MIGRATION).sub("<%= migration_version %>", "[7.1]")
    dummy = migration_body(DUMMY_MIGRATION)

    assert_equal template, dummy,
                 "The dummy database must exercise the exact migration users receive, " \
                 "including column options, declaration order, constraints, and helpers."
  end

  test "neither migration declares the same generated column twice inside one table" do
    [TEMPLATE_MIGRATION, DUMMY_MIGRATION].each do |path|
      table_column_names_in(path).each do |table, columns|
        duplicates = columns.tally.select { |_column, count| count > 1 }.keys
        assert_empty duplicates,
                     "#{File.basename(path)} declares #{duplicates.join(", ")} more than once in #{table}."
      end
    end
  end

  test "the migration generated for a host executes against a scratch database" do
    run_generator %w[--skip-questions]
    migration = Dir.glob(File.join(destination_root, "db/migrate/*_create_clickwrap_tables.rb")).sole

    Dir.mktmpdir("clickwrap-generated-migration") do |directory|
      database = File.join(directory, "scratch.sqlite3")
      stdout, stderr, status = Open3.capture3(
        { "RAILS_ENV" => "test" },
        RbConfig.ruby,
        "-e",
        scratch_migration_program,
        migration,
        database
      )

      assert status.success?, <<~MESSAGE
        The migration produced by `clickwrap:install` did not execute on a clean database.
        stdout:
        #{stdout}
        stderr:
        #{stderr}
      MESSAGE
    end
  end

  private

  # The Sitepress content directory a real application already serves its legal
  # pages from. `last_updated:` is the front-matter key such a page usually
  # carries already, and it is the one Clickwrap reads the version label from.
  # A page can be written without it to exercise the application that has front
  # matter but has never versioned anything.
  def write_sitepress_legal_pages(terms_names_its_own_version: true, privacy_names_its_own_version: true)
    directory = File.join(destination_root, "app/content/pages/legal")
    FileUtils.mkdir_p(directory)

    File.write(File.join(directory, "terms.html.md"),
               legal_page("Terms of Service", names_its_own_version: terms_names_its_own_version))
    File.write(File.join(directory, "privacy.html.md"),
               legal_page("Privacy Notice", names_its_own_version: privacy_names_its_own_version))
  end

  def legal_page(title, names_its_own_version:)
    front_matter = ["---", "title: #{title}"]
    front_matter << "last_updated: 2026-04-01" if names_its_own_version
    front_matter << "---"

    "#{front_matter.join("\n")}\n\n# #{title}\n\nThe text this application already serves.\n"
  end

  # Bundler's own lockfile shape, because the resolved bundle is what the
  # installer reads — a Gemfile line can name a gem this application never
  # resolves.
  def write_gemfile_lock_bundling(*gem_names)
    lockfile = ["GEM", "  remote: https://rubygems.org/", "  specs:"]
    gem_names.each { |name| lockfile << "    #{name} (1.0.0)" }
    lockfile.push("", "PLATFORMS", "  ruby", "", "DEPENDENCIES")
    gem_names.each { |name| lockfile << "  #{name}" }

    File.write(File.join(destination_root, "Gemfile.lock"), "#{lockfile.join("\n")}\n")
  end

  # A real `version:` argument, never the commented example that documents the
  # override for sources which cannot carry front matter.
  def assert_no_version_declarations(config)
    refute_match(/^\s+version:/, config,
                 "a document whose own file names its version must be declared without a `version:` line")
  end

  # The generated declarations, one string each, so an assertion can be about
  # exactly one of them.
  def document_declarations_in(config)
    declarations = config.scan(/^Clickwrap\.document :\w+,\n(?:^[ \t]+.+\n)+/)
    assert_equal 2, declarations.length, "expected the Terms and the Privacy Notice to be declared"

    declarations
  end

  def column_names_in(path)
    source = File.read(path)
    plain = source.scan(
      /^\s*t\.(?:string|text|datetime|decimal|bigint|uuid|integer|json|jsonb|boolean|references) :(\w+)/
    )
    sent = source.scan(/^\s*t\.send\(\w+, :(\w+)/)
    (plain + sent).flatten.uniq
  end

  def migration_body(path)
    File.read(path).match(/class CreateClickwrapTables\b.*\z/m).to_s
  end

  def table_column_names_in(path)
    File.read(path).scan(/create_table :(\w+).*? do \|t\|\n(.*?)^    end$/m).to_h do |table, body|
      columns = body.each_line.flat_map do |line|
        case line
        when /^\s*t\.references :(\w+)(.*)$/
          base = Regexp.last_match(1)
          Regexp.last_match(2).include?("polymorphic: true") ? ["#{base}_type", "#{base}_id"] : ["#{base}_id"]
        when /^\s*t\.timestamps\b/
          %w[created_at updated_at]
        when /^\s*t\.send\([^,]+, :(\w+)/, /^\s*t\.\w+ :(\w+)/
          [Regexp.last_match(1)]
        else
          []
        end
      end

      [table, columns]
    end
  end

  def table_names_in(path)
    File.read(path).scan(/create_table :(\w+)/).flatten.uniq
  end

  def index_names_in(path)
    File.read(path).scan(/name: "(index_\w+)"/).flatten.uniq
  end

  def foreign_keys_in(path)
    File.read(path).scan(
      /add_(?:clickwrap_)?foreign_key :(\w+), :(\w+),\s*\n?\s*column: :(\w+), name: "(fk_\w+)"/
    ).uniq
  end

  def scratch_migration_program
    <<~'RUBY'
      require "bundler/setup"
      require "rails"
      require "active_record"

      class ClickwrapScratchApplication < Rails::Application
        # Never let Rails infer the gem checkout as this throwaway host's root.
        # Rails 7.1 would otherwise load the engine's config/routes.rb as the
        # application's routes before the Clickwrap engine itself was loaded.
        config.root = File.dirname(ARGV.fetch(1))
        config.eager_load = false
        config.generators.orm :active_record, primary_key_type: :uuid
      end

      ClickwrapScratchApplication.initialize!
      ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ARGV.fetch(1))
      ActiveRecord::Migration.verbose = false
      load ARGV.fetch(0)
      CreateClickwrapTables.new.migrate(:up)

      expected = %w[
        clickwrap_documents clickwrap_document_versions clickwrap_policy_revisions
        clickwrap_presentations clickwrap_recording_sequences clickwrap_events clickwrap_event_statements
        clickwrap_event_documents clickwrap_statement_states
        clickwrap_statement_identity_locks clickwrap_request_evidence
        clickwrap_legal_holds clickwrap_chain_heads clickwrap_external_actions
        clickwrap_disposition_plans clickwrap_receipt_accesses
        clickwrap_integrity_attestations
      ]
      missing = expected - ActiveRecord::Base.connection.tables
      abort "Generated migration omitted: #{missing.join(', ')}" unless missing.empty?

      connection = ActiveRecord::Base.connection
      actor_id = connection.columns(:clickwrap_presentations).find { |column| column.name == "actor_id" }
      abort "Generated actor_id was #{actor_id.type}, not string" unless actor_id.type == :string

      recording_sequence_id = connection.columns(:clickwrap_recording_sequences).find { |column| column.name == "id" }
      event_recording_sequence = connection.columns(:clickwrap_events).find { |column| column.name == "recording_sequence" }
      unless recording_sequence_id.type == :integer && event_recording_sequence.type == :integer
        abort "Generated recording order did not stay numeric inside a UUID host"
      end

      precision_failures = expected.flat_map do |table|
        connection.columns(table).filter_map do |column|
          next unless [:datetime, :timestamp].include?(column.type)
          "#{table}.#{column.name}=#{column.precision.inspect}" unless column.precision == 6
        end
      end
      abort "Generated timestamps lost precision: #{precision_failures.join(', ')}" if precision_failures.any?

      presentation_indexes = connection.indexes(:clickwrap_presentations).map(&:columns)
      abort "Generated migration omitted presentation expiry index" unless presentation_indexes.include?(["expires_at"])

      presentation_checks = connection.check_constraints(:clickwrap_presentations).map(&:name)
      abort "Generated migration omitted presentation state check" unless presentation_checks.include?("chk_clickwrap_presentations_state")
    RUBY
  end
end
