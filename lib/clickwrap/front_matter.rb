# frozen_string_literal: true

module Clickwrap
  # The leading YAML front-matter block — the Jekyll/Sitepress convention that
  # content-file Rails apps already use to describe their own pages:
  #
  #   ---
  #   title: Terms of Service
  #   last_updated: 2026-01-01
  #   ---
  #
  # Clickwrap reads it in exactly two places, and this module is both so the
  # two can never disagree about what counts as front matter: the Markdown
  # renderer strips the block from the RENDERED representation (the source
  # digest still covers the exact file bytes, front matter included), and a
  # document declared without a `version:` resolves its version label from the
  # block's own `clickwrap_version:` or `last_updated:` key — the file that IS
  # the legal text also names its own version, so there is no second copy of
  # the label anywhere to drift.
  module FrontMatter
    # `---` opens; `---` or `...` closes (both are valid YAML document ends).
    LEADING_BLOCK = /\A---\s*\n(.*?)\n(?:---|\.\.\.)\s*(?:\n|\z)/m

    # `clickwrap_version:` outranks `last_updated:` on purpose: a same-day
    # point release (a typo fix that still changes bytes) needs a fresh label
    # while the human-facing date stays put.
    VERSION_LABEL_KEYS = %w[clickwrap_version last_updated].freeze

    def self.strip(text)
      text.sub(LEADING_BLOCK, "")
    end

    # The version label the front matter declares, or nil when the bytes carry
    # no front matter or no version key. Only simple top-level `key: value`
    # lines are read — a version label is a short string, and anything that
    # needs real YAML structure to express is not a version label.
    def self.version_label_in(bytes)
      block = bytes.to_s[LEADING_BLOCK, 1]
      return nil if block.nil?

      pairs = block.scan(/^(\w+):[ \t]*(.+?)[ \t]*$/).to_h
      VERSION_LABEL_KEYS.each do |key|
        value = unquote(pairs[key])
        return value unless value.nil?
      end
      nil
    end

    def self.unquote(value)
      return nil if value.nil?

      unquoted = value.strip
      if (unquoted.start_with?('"') && unquoted.end_with?('"')) ||
         (unquoted.start_with?("'") && unquoted.end_with?("'"))
        unquoted = unquoted[1..-2].to_s
      end
      unquoted.empty? ? nil : unquoted
    end
    private_class_method :unquote
  end
end
