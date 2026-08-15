# frozen_string_literal: true

module Clickwrap
  # The exact rendered bytes of one published document version.
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

      # The linked representation is the exact rendered snapshot bound into the
      # presentation, not mutable source and never raw unsanitized HTML.
      response.headers["X-Content-Type-Options"] = "nosniff"
      response.headers["Content-Security-Policy"] =
        "default-src 'none'; img-src data:; style-src 'unsafe-inline'; " \
        "base-uri 'none'; form-action 'none'; frame-ancestors 'self'; sandbox"
      response.headers["Referrer-Policy"] = "no-referrer"
      response.headers["Cache-Control"] = "public, max-age=31536000, immutable"

      # A published representation is derived from a specific source artifact.
      # Refuse to serve either half of a version whose other half has stopped
      # matching its publication digest; otherwise a corrupt source row could
      # remain publicly vouched for merely because the rendered snapshot was
      # untouched.
      version.content_bytes
      send_data version.rendered_bytes,
                type: version.rendered_media_type.presence || version.media_type,
                filename: download_filename(version, version.rendered_media_type.presence || version.media_type),
                disposition: "inline"
    rescue DocumentDigestMismatchError
      # The stored bytes no longer match their recorded digest. Serving them
      # anyway would be the one thing this action must never do.
      head :unprocessable_entity
    end

    private

    def download_filename(version, media_type)
      base = [version.document&.document_key, version.version_label, version.locale].compact.join("-")

      "#{base.parameterize}#{extension_for(media_type)}"
    end

    def extension_for(media_type)
      case media_type.to_s.split(";", 2).first
      when "text/markdown" then ".md"
      when "text/html" then ".html"
      when "text/plain" then ".txt"
      when "application/pdf" then ".pdf"
      else ""
      end
    end
  end
end
