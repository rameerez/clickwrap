# frozen_string_literal: true

require "test_helper"

# A host rewords a gem statement by shipping the same key in its own locale
# file — that is the documented override path, and it works only if I18n loads
# the gem's files FIRST and the host's LAST. Rails::Engine's :add_locales
# initializer guarantees exactly that (engine paths are unshifted ahead of the
# application's). The gem once also appended its locales manually to
# `app.config.i18n.load_path`, which put a second copy AFTER the host's files:
# every host override silently lost to the gem's defaults, discovered when a
# real host's "He leído la Política de Privacidad." kept rendering as the
# gem's "Doy por recibida...". These tests pin both the outcome and the
# ordering that produces it.
class HostLocaleOverrideTest < ActiveSupport::TestCase
  test "the host's wording for a gem key wins over the gem's default" do
    assert_equal "He leído la Política de Privacidad.",
                 I18n.t("clickwrap.statements.acknowledgment.privacy_notice", locale: :es)
  end

  test "every gem locale file loads before every host locale file" do
    engine_locales = Clickwrap::Engine.root.join("config", "locales").to_s
    host_locales = Rails.root.join("config", "locales").to_s

    last_engine = I18n.load_path.rindex { |path| path.to_s.start_with?(engine_locales) }
    first_host = I18n.load_path.index { |path| path.to_s.start_with?(host_locales) }

    refute_nil last_engine, "the gem's locale files never made it into I18n.load_path"
    refute_nil first_host, "the dummy host's locale files never made it into I18n.load_path"
    assert last_engine < first_host,
           "gem locales must load before host locales, or host overrides lose"
  end
end
