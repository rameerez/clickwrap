# frozen_string_literal: true

require "test_helper"
require "rails/generators/test_case"
require "generators/clickwrap/install_generator"
require "open3"
require "rbconfig"
require "tmpdir"

# The README quickstart, executed.
#
# It is the one document every user reads, and until this file existed it was
# the only one nothing verified: `documentation_examples_test.rb` evaluates
# declaration fences, and every other generator test asserts on the TEXT of what
# was written rather than on what happens when somebody runs it.
#
# So this walks the quickstart exactly as written, in a throwaway application
# built only from what the installer emitted:
#
#   install → migrate → declare → has_clickwraps → publish → render the form →
#   submit the token that render produced → the evidence row exists → the
#   receipt verifies
#
# It runs in a SUBPROCESS on its own SQLite database, because the point is a
# fresh application booting the generated initializer, the generated routes,
# and the generated migration with nothing from this suite in scope.
class QuickstartTest < Rails::Generators::TestCase
  tests Clickwrap::Generators::InstallGenerator
  destination Dir.mktmpdir("clickwrap-quickstart-")
  setup :prepare_destination

  teardown { FileUtils.rm_rf(destination_root) }

  test "the README quickstart, run end to end, produces evidence that verifies" do
    write_host_application_files

    # Step 1 and 2 of the quickstart, verbatim: the installer, no questions.
    # (`--skip-questions` is what a non-interactive run takes anyway; the
    # quickstart's interactive run reaches the same collect-nothing posture.)
    run_generator %w[--skip-questions]

    assert_file "config/initializers/clickwrap.rb"
    assert_file "config/clickwrap.rb"
    assert_file "app/content/legal/terms.md"
    assert_file "config/routes.rb", /mount Clickwrap::Engine/

    stdout, stderr, status = Open3.capture3(
      { "RAILS_ENV" => "test" },
      RbConfig.ruby, "-e", quickstart_program,
      destination_root, File.join(destination_root, "quickstart.sqlite3")
    )

    assert status.success?, <<~MESSAGE
      The README quickstart did not run end to end against a fresh application.
      stdout:
      #{stdout}
      stderr:
      #{stderr}
    MESSAGE

    # Each line is printed by the subprocess only after the step actually
    # happened, so this is the quickstart's own trace rather than an assertion
    # about it.
    %w[migrated published rendered submitted recorded verified].each do |step|
      assert_match(/^ok: #{step}$/, stdout, "the quickstart never reached '#{step}':\n#{stdout}")
    end
  end

  private

  # Everything the quickstart assumes a host already has: a routes file to mount
  # into, and the user model the installer tells you to add `has_clickwraps` to.
  def write_host_application_files
    FileUtils.mkdir_p(File.join(destination_root, "config"))
    File.write(File.join(destination_root, "config/routes.rb"),
               "Rails.application.routes.draw do\nend\n")

    FileUtils.mkdir_p(File.join(destination_root, "app/models"))
    File.write(File.join(destination_root, "app/models/user.rb"), <<~RUBY)
      class User < ActiveRecord::Base
        has_clickwraps
      end
    RUBY
  end

  def quickstart_program
    File.read(File.expand_path("quickstart_program.rb", __dir__))
  end
end
