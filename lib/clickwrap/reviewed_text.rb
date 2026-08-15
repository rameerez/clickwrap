# frozen_string_literal: true

module Clickwrap
  # Detects scaffolding language that must never be mistaken for a reviewed
  # operational reason. This deliberately does not reject the lowercase word
  # "todo": it is an ordinary Spanish word. It catches conventional developer
  # markers and generated English placeholders instead.
  module ReviewedText
    PLACEHOLDER_PATTERNS = [
      /\A(?:TODO|TBD|FIXME)(?:\b|:)/,
      /replace (?:this|with|me)/i,
      /your reviewed (?:purpose|reason|decision)/i,
      /placeholder/i,
      /\A\.{3}\z/
    ].freeze

    module_function

    def placeholder?(value)
      text = value.to_s.strip
      text.present? && PLACEHOLDER_PATTERNS.any? { |pattern| pattern.match?(text) }
    end

    def present_and_reviewed?(value)
      value.to_s.strip.present? && !placeholder?(value)
    end
  end
end
