# frozen_string_literal: true

require "test_helper"

# `config.hotwire_native_document_links` is one declarative answer for how
# document links behave inside a Hotwire Native app, doing both halves
# coherently: the signed href (absolutized against the canonical host for the
# external browser) and the navigation attributes. When set, it answers native
# renders entirely; the per-request `document_link_html_options_with` hook
# keeps answering everything else.
class HotwireNativeDocumentLinksTest < ActiveSupport::TestCase
  # A controller as turbo-rails leaves it: `hotwire_native_app?` answers per
  # request. The engine-routes stub keeps the path half testable without a
  # full routing round trip.
  class NativeAwareController
    include Clickwrap::ControllerHelpers

    attr_accessor :native

    def hotwire_native_app? = @native

    def clickwrap_engine_routes
      routes = Object.new
      def routes.document_version_path(id) = "/agreements/documents/#{id}"
      routes
    end
  end

  class NativeAwareView
    include Clickwrap::ViewHelpers

    attr_accessor :native

    def hotwire_native_app? = @native
  end

  Version = Struct.new(:id)

  # --- Configuration refusals ------------------------------------------------

  test "external_browser without a canonical host is refused with the reason" do
    config = Clickwrap::Configuration.new

    error = assert_raises(Clickwrap::ConfigurationError) do
      config.hotwire_native_document_links = { open_in: :external_browser }
    end

    assert_match(/needs a `canonical_host:`/, error.message)
    assert_match(/WebView/, error.message)
  end

  test "a non-https canonical host is refused — the link opens on a phone" do
    config = Clickwrap::Configuration.new

    error = assert_raises(Clickwrap::ConfigurationError) do
      config.hotwire_native_document_links =
        { open_in: :external_browser, canonical_host: "http://www.example.com" }
    end

    assert_match(%r{absolute https://}, error.message)
  end

  test "an unknown mode and unknown options are refused by name" do
    config = Clickwrap::Configuration.new

    error = assert_raises(Clickwrap::ConfigurationError) do
      config.hotwire_native_document_links = { open_in: :new_tab }
    end
    assert_match(/:external_browser or :same_screen/, error.message)

    error = assert_raises(Clickwrap::ConfigurationError) do
      config.hotwire_native_document_links = { open_in: :same_screen, host: "x" }
    end
    assert_match(/:host/, error.message)
  end

  test "same_screen refuses a canonical host it would never use" do
    config = Clickwrap::Configuration.new

    error = assert_raises(Clickwrap::ConfigurationError) do
      config.hotwire_native_document_links =
        { open_in: :same_screen, canonical_host: "https://www.example.com" }
    end

    assert_match(/has no meaning there/, error.message)
  end

  test "a callable canonical host resolves late and is validated when it answers" do
    config = Clickwrap::Configuration.new
    config.hotwire_native_document_links = {
      open_in: :external_browser,
      canonical_host: -> { "https://www.example.com/" }
    }

    assert_equal "https://www.example.com", config.hotwire_native_canonical_host,
                 "trailing slashes are trimmed because the engine path begins with one"

    config.hotwire_native_document_links = {
      open_in: :external_browser,
      canonical_host: -> { "ftp://example.com" }
    }
    assert_raises(Clickwrap::ConfigurationError) { config.hotwire_native_canonical_host }
  end

  # --- The href half ---------------------------------------------------------

  test "a native request gets the canonical-host absolute URL; the web keeps the path" do
    Clickwrap.config.hotwire_native_document_links = {
      open_in: :external_browser,
      canonical_host: "https://www.example.com"
    }
    controller = NativeAwareController.new
    version = Version.new("01ARZ3NDEKTSV4RRFFQ69G5FAV")

    controller.native = true
    assert_equal "https://www.example.com/agreements/documents/01ARZ3NDEKTSV4RRFFQ69G5FAV",
                 controller.clickwrap_document_version_path_for_presentation(version)

    controller.native = false
    assert_equal "/agreements/documents/01ARZ3NDEKTSV4RRFFQ69G5FAV",
                 controller.clickwrap_document_version_path_for_presentation(version)
  end

  test "same_screen keeps plain paths for native path configuration to route" do
    Clickwrap.config.hotwire_native_document_links = { open_in: :same_screen }
    controller = NativeAwareController.new
    controller.native = true

    assert_equal "/agreements/documents/x",
                 controller.clickwrap_document_version_path_for_presentation(Version.new("x"))
  end

  test "with nothing configured, paths are untouched even on native" do
    controller = NativeAwareController.new
    controller.native = true

    assert_equal "/agreements/documents/x",
                 controller.clickwrap_document_version_path_for_presentation(Version.new("x"))
  end

  # --- The attributes half ---------------------------------------------------

  test "a native render gets the external-browser attributes without consulting the hook" do
    Clickwrap.config.hotwire_native_document_links = {
      open_in: :external_browser,
      canonical_host: "https://www.example.com"
    }
    Clickwrap.config.document_link_html_options_with = lambda do |_document|
      raise "the per-request hook must not be consulted for a native render the seam answers"
    end

    view = NativeAwareView.new
    view.native = true

    assert_equal({ target: "_blank", rel: "noopener", data: { turbo: false } },
                 view.clickwrap_document_link_html_options)
  end

  test "same_screen renders a plain link — the app's native screen rules route it" do
    Clickwrap.config.hotwire_native_document_links = { open_in: :same_screen }
    view = NativeAwareView.new
    view.native = true

    assert_equal({}, view.clickwrap_document_link_html_options)
  end

  test "non-native renders keep answering through the hook" do
    Clickwrap.config.hotwire_native_document_links = {
      open_in: :external_browser,
      canonical_host: "https://www.example.com"
    }
    view = NativeAwareView.new
    view.native = false

    assert_equal({ target: "_blank", rel: "noopener" },
                 view.clickwrap_document_link_html_options)
  end

  # --- A per-screen answer ---------------------------------------------------

  test "open_in takes a callable, so one app can answer differently per screen" do
    # The auth sheet has to escape the WebView or the half-filled signup form
    # goes with it; a document sheet inside a signed-in funnel is routed by the
    # app itself. One application, two right answers.
    Clickwrap.config.hotwire_native_document_links = {
      open_in: ->(context) { context.signing_up? ? :external_browser : :same_screen },
      canonical_host: "https://www.example.com"
    }

    controller = SigningUpAwareController.new
    controller.native = true

    controller.signing_up = true
    assert_equal "https://www.example.com/agreements/documents/x",
                 controller.clickwrap_document_version_path_for_presentation(Version.new("x"))

    controller.signing_up = false
    assert_equal "/agreements/documents/x",
                 controller.clickwrap_document_version_path_for_presentation(Version.new("x"))
  end

  test "the attributes half asks the callable with the same controller the href did" do
    # Both halves of one link have to agree. If the href absolutized against
    # the canonical host and the attributes said "plain same-screen link", the
    # tap would leave the WebView with no `data-turbo-false` to carry it there.
    Clickwrap.config.hotwire_native_document_links = {
      open_in: ->(context) { context.signing_up? ? :external_browser : :same_screen },
      canonical_host: "https://www.example.com"
    }

    controller = SigningUpAwareController.new
    controller.native = true
    controller.signing_up = true
    view = ControllerBackedView.new(controller)

    assert_equal({ target: "_blank", rel: "noopener", data: { turbo: false } },
                 view.clickwrap_document_link_html_options)

    controller.signing_up = false
    assert_equal({}, view.clickwrap_document_link_html_options)
  end

  test "a callable open_in still needs a canonical host, because it might say external_browser" do
    config = Clickwrap::Configuration.new

    error = assert_raises(Clickwrap::ConfigurationError) do
      config.hotwire_native_document_links = { open_in: ->(_context) { :same_screen } }
    end

    assert_match(/needs a `canonical_host:`/, error.message)
    assert_match(/nothing at boot can rule out/, error.message)
  end

  test "a callable that answers something else is refused when it answers" do
    Clickwrap.config.hotwire_native_document_links = {
      open_in: ->(_context) { :new_tab },
      canonical_host: "https://www.example.com"
    }
    controller = SigningUpAwareController.new
    controller.native = true

    error = assert_raises(Clickwrap::ConfigurationError) do
      controller.clickwrap_document_version_path_for_presentation(Version.new("x"))
    end

    assert_match(/answered :new_tab/, error.message)
    assert_match(/:external_browser or :same_screen/, error.message)
  end

  class SigningUpAwareController < NativeAwareController
    attr_accessor :signing_up

    def signing_up? = @signing_up
  end

  # An ActionView-shaped double: the view knows its controller, which is how
  # both halves of a document link reach the same answer.
  class ControllerBackedView
    include Clickwrap::ViewHelpers

    attr_reader :controller

    def initialize(controller)
      @controller = controller
    end

    def hotwire_native_app? = controller.hotwire_native_app?
  end
end
