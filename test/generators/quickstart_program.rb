# frozen_string_literal: true

# The README quickstart, as a program. Run by test/generators/quickstart_test.rb
# in a subprocess, against an application containing only what
# `rails generate clickwrap:install` emitted plus the two files the quickstart
# tells you to already have.
#
# Every `ok:` line is printed AFTER the step it names actually happened, so the
# output is a trace of the quickstart running rather than a description of it.
#
# ARGV: the generated application root, the scratch database path.

require "bundler/setup"
require "logger"
require "active_record"
require "action_controller/railtie"
require "action_view/railtie"
require "clickwrap"

application_root, database = ARGV

# --- A Rails application made of the generated files -------------------------

class QuickstartApplication < Rails::Application
  config.root = ARGV.fetch(0)
  config.eager_load = false
  config.secret_key_base = "quickstart-secret-key-base-for-this-throwaway-application"
  config.logger = Logger.new(IO::NULL)
  config.consider_all_requests_local = true

  # The generated config/clickwrap.rb points at the generated legal files with
  # Rails.root.join, and the generated initializer and routes are picked up
  # from this root as they would be in any host.
  config.autoload_paths << File.join(ARGV.fetch(0), "app/models")
end

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: database)
QuickstartApplication.initialize!

# --- Step: migrate ------------------------------------------------------------

ActiveRecord::Migration.verbose = false

Dir[File.join(application_root, "db/migrate/*.rb")].each do |path|
  load path
  class_name = File.basename(path, ".rb").sub(/\A\d+_/, "").split("_").map(&:capitalize).join
  Object.const_get(class_name).new.migrate(:up)
end

# The host's own table. The quickstart's "add has_clickwraps to your user
# model" needs a model to add it to.
ActiveRecord::Schema.define do
  create_table :users, force: true do |t|
    t.string :email, null: false
    t.timestamps
  end
end

abort "the engine is not mounted" unless Clickwrap::ControllerHelpers.engine_is_mounted?
puts "ok: migrated"

# --- Step: declare ------------------------------------------------------------

Clickwrap::Services::LoadPolicies.new(root: application_root, paths: ["config/clickwrap.rb"]).call

abort "no :signup policy was declared" unless Clickwrap.policies["signup"]
abort "no documents were declared" if Clickwrap.documents.empty?

# --- Step: publish ------------------------------------------------------------

Clickwrap.publish!

published = Clickwrap::Document.find_by(document_key: "terms")&.current_version
abort "terms was not published" unless published&.published?
abort "the published bytes do not match their digest" unless published.verify_content_digest
puts "ok: published"

# --- Step: render the form ----------------------------------------------------

user = User.create!(email: "person@example.com")

# A real controller with a real request behind the view, because that is where
# the signed document URL comes from: the mounted engine's route helpers, which
# need a request to answer.
class SignupsController < ActionController::Base
  include Rails.application.routes.url_helpers
  include Rails.application.routes.mounted_helpers

  def current_user = User.first
end

request = ActionDispatch::Request.new(Rack::MockRequest.env_for("http://example.test/signup"))
controller = SignupsController.new
controller.set_request!(request)
controller.set_response!(SignupsController.make_response!(request))

view = ActionView::Base.with_empty_template_cache.new(
  ActionView::LookupContext.new(ActionController::Base.view_paths), {}, controller
)

html = view.form_with(url: "/signup", method: :post) do |form|
  form.clickwrap :signup, actor: user, submit: "Create account"
end.to_s

abort "the form rendered no presentation token" unless html.include?("clickwrap_submission[presentation_token]")
abort "the form rendered no submit button" unless html.include?("Create account")
abort "a control was rendered preselected" if html.match?(/\bchecked\b/)
puts "ok: rendered"

# --- Step: submit the token that render produced -------------------------------
#
# Read back out of the rendered HTML, the way a browser would. A test that
# minted its own token would be proving something the product does not allow.

token = html[/name="clickwrap_submission\[presentation_token\]"[^>]*value="([^"]+)"/, 1] ||
        html[/value="([^"]+)"[^>]*name="clickwrap_submission\[presentation_token\]"/, 1]
abort "could not read the presentation token back out of the rendered form" unless token

answers = html.scan(/name="clickwrap_submission\[answers\]\[([^\]]+)\]"/).flatten.uniq.to_h { |key| [key, "1"] }
abort "the form rendered no answer controls" if answers.empty?

result = Clickwrap.capture!(
  :signup,
  actor: user,
  submission: Clickwrap::Submission.new(presentation_token: token, answers: answers)
)
puts "ok: submitted"

# --- Step: the evidence row exists ---------------------------------------------

event = Clickwrap::Event.find_by(id: result.event_id)
abort "no evidence row was written" unless event
abort "the event is not the signup policy" unless event.policy_key == "signup"
abort "the actor is not the user who submitted" unless event.actor_id.to_s == user.id.to_s
abort "the projection does not answer yes" unless user.clickwraps.current_for?(:signup)
puts "ok: recorded"

# --- Step: the receipt verifies ------------------------------------------------

receipt = event.receipt
verification = receipt.verify
abort "the receipt does not verify: #{verification.message}" unless verification.success?

standalone = Clickwrap::ReceiptVerifier.verify(receipt.to_canonical_json)
abort "the standalone verifier reported #{standalone.status}" if standalone.status == "failed"
puts "ok: verified"
