# frozen_string_literal: true

module Clickwrap
  # The id of the version in force of each document: the version
  # `Document#current_version` returns, for one locale at one moment.
  #
  # A re-acceptance gate asks this on every protected write, once for each
  # policy that recorded the agreement. Those policies usually bind the same
  # documents, so each document is looked up once and the answer is kept for
  # the life of this object. The lookup reads ids only, because a version row
  # also holds the document's bytes and this question needs none of them.
  #
  # A tenant's own document wins over the shared one, as the presenter chooses
  # them. Evidence recorded in a tenant that was offered the shared document
  # is therefore compared with the shared document's version in force.
  class DocumentVersionsInForce
    def initialize(locale: I18n.locale, at: Clickwrap.now)
      @locale = locale
      @at = at
      @ids = {}
    end

    # nil when the document is not published or has no version in force.
    def id_for(document_key, tenant_key: nil)
      key = [document_key.to_s, tenant_key.presence]
      return @ids[key] if @ids.key?(key)

      @ids[key] = look_up(*key)
    end

    private

    def look_up(document_key, tenant_key)
      document_id = document_id_for(document_key, tenant_key)
      return nil unless document_id

      DocumentVersion.where(document_id: document_id).presentable_newest_first(@at, @locale).pick(:id)
    end

    def document_id_for(document_key, tenant_key)
      ids = Document.where(document_key: document_key, tenant_key: [tenant_key, nil].uniq)
                    .pluck(:tenant_key, :id)
                    .to_h

      ids.fetch(tenant_key) { ids[nil] }
    end
  end
end
