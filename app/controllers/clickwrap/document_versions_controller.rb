# frozen_string_literal: true

module Clickwrap
  # The exact bytes of one published document version.
  #
  # This is where every document link in every presentation points, and where an
  # auditor reading a three-year-old receipt ends up. Both get the same response
  # from the same row, verified against the digest that was recorded when it was
  # published — `DocumentVersion#content_bytes` refuses to hand back bytes that
  # no longer match, because silently serving edited content would turn this
  # action into a way to launder a changed document into an old agreement.
  #
  # Retired versions stay reachable on purpose. A version stops being presentable
  # when it is retired; it never stops being the thing somebody agreed to.
  class DocumentVersionsController < ApplicationController
    # Published legal documents are read before anyone is signed in — the signup
    # form links to them, and that is the moment they matter most. The host's
    # authentication filter is skipped here and only here. (`raise: false`
    # because most hosts have neither of these filters; between them they cover
    # the Rails authentication generator and Devise.)
    skip_before_action :require_authentication, raise: false
    skip_before_action :authenticate_user!, raise: false

    def show
      version = DocumentVersion.find_by(id: params[:id])
      return head :not_found if version.nil? || !version.published?

      # A document is data, not markup this application vouches for: tell the
      # browser to respect the recorded media type instead of sniffing its own.
      response.headers["X-Content-Type-Options"] = "nosniff"

      send_data version.content_bytes,
                type: version.media_type,
                filename: download_filename(version),
                disposition: "inline"
    rescue DocumentDigestMismatchError
      # The stored bytes no longer match their recorded digest. Serving them
      # anyway would be the one thing this action must never do.
      head :unprocessable_entity
    end

    private

    def download_filename(version)
      base = [version.document&.key, version.version_label, version.locale].compact.join("-")

      "#{base.parameterize}#{extension_for(version.media_type)}"
    end

    def extension_for(media_type)
      case media_type.to_s
      when "text/markdown" then ".md"
      when "text/html" then ".html"
      when "text/plain" then ".txt"
      when "application/pdf" then ".pdf"
      else ""
      end
    end
  end
end
