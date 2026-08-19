# frozen_string_literal: true

module Clickwrap
  # Every human-facing string in a policy — an assertion, a label, a link
  # label, a call to action — can be written three ways:
  #
  #   statement: "I agree to the Terms."          # a literal
  #   statement: :"clickwrap.signup.terms"        # an I18n key
  #   statement: { en: "I agree", es: "Acepto" }  # a locale map
  #
  # Whichever form the policy uses, Clickwrap resolves it to actual text before
  # the presentation is built, and stores the resolved text and locale in the
  # evidence. Storing only an I18n key would be a false economy: the key's
  # meaning can change in a later deploy, and then the receipt no longer says
  # what the server bound to the presentation.
  #
  # A missing translation fails closed. Presenting a required legal statement
  # as a raw key, a blank string, or an unexpected fallback language would put
  # something in front of a person and then record it as though it had been
  # legible to them.
  class LocalizedText
    attr_reader :declaration

    def initialize(declaration)
      @declaration = declaration
      freeze
    end

    # Returns [text, locale_actually_used].
    def resolve(locale:, interpolations: {})
      case declaration
      when String then [declaration, locale.to_s]
      when Symbol then resolve_i18n_key(locale, interpolations)
      when Hash then resolve_locale_map(locale)
      when Proc then [declaration.call(locale).to_s, locale.to_s]
      when nil then [nil, nil]
      else
        raise DefinitionError,
              "A policy text must be a String, an I18n key Symbol, a locale Hash, or a " \
              "callable, got #{declaration.class}"
      end
    end

    def present? = !declaration.nil?

    # How the declaration appears in the compiled policy snapshot. The snapshot
    # records the shape, not the resolved text, because the same revision
    # legitimately renders differently per locale.
    def to_snapshot
      case declaration
      when String then { "kind" => "literal", "value" => declaration }
      when Symbol then { "kind" => "i18n_key", "value" => declaration.to_s }
      when Hash then { "kind" => "locale_map", "value" => declaration.transform_keys(&:to_s).transform_values(&:to_s) }
      when Proc then { "kind" => "callable" }
      end
    end

    private

    def resolve_i18n_key(locale, interpolations)
      unless defined?(::I18n)
        raise DefinitionError,
              "#{declaration.inspect} looks like an I18n key but I18n is not loaded. " \
              "Use a literal string or a locale map instead."
      end

      text = ::I18n.t(declaration, locale:, default: nil, **interpolations)

      raise MissingTranslation.new(key: declaration, locale:) if text.nil? || text.to_s.strip.empty?

      [text.to_s, locale.to_s]
    end

    def resolve_locale_map(locale)
      normalized = declaration.transform_keys(&:to_s)
      wanted = locale.to_s

      text = normalized[wanted] || normalized[wanted.split("-").first]

      raise MissingTranslation.new(key: declaration.keys, locale:) if text.nil?

      [text.to_s, wanted]
    end
  end

  # Raised when a required human-facing string has no text for the requested
  # locale. Clickwrap will not present a legal statement in a language the
  # policy did not declare, and will not record one it could not render.
  class MissingTranslation < DefinitionError
    attr_reader :key, :locale

    def initialize(key:, locale:)
      @key = key
      @locale = locale
      super(
        "No text for #{key.inspect} in locale #{locale.inspect}. Add the translation, or " \
        "restrict the policy to the locales it can actually present."
      )
    end
  end
end
