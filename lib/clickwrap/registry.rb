# frozen_string_literal: true

module Clickwrap
  # A small thread-safe registry for compiled documents, policies, and retention
  # classes.
  #
  # Definitions are declared once at boot and read on every request, so writes
  # take a lock and reads do not. A reload clears the complete registry before
  # loading the declaration files again. Seeing the same key twice inside one
  # load is therefore always ambiguous and is refused instead of letting file
  # order silently decide which policy governs a production action.
  #
  # A registry may carry a seed: built-in entries that are its floor rather
  # than its contents. Clearing re-runs the seed, so a reload returns to the
  # built-ins, never to nothing — which is what lets a gem-shipped default
  # (the indefinite retention class) survive every `to_prepare`.
  class Registry
    def initialize(kind, &seed)
      @kind = kind
      @entries = {}
      @mutex = Mutex.new
      @seed = seed
      @seed&.call(self)
    end

    attr_reader :kind

    def register(key, definition)
      @mutex.synchronize do
        if @entries.key?(key)
          raise DefinitionError,
                "The #{kind} key #{key.inspect} is declared more than once. Give every " \
                "#{kind} one stable key; Clickwrap will not let load order silently replace " \
                "a server-owned definition."
        end

        @entries[key] = definition
      end
      definition
    end

    def fetch(key, &fallback)
      entry = @entries[key]
      return entry if entry
      return fallback.call if fallback

      raise NotDefinedError, "No #{kind} registered for #{key.inspect}"
    end

    def [](key) = @entries[key]
    def key?(key) = @entries.key?(key)
    def keys = @entries.keys
    def values = @entries.values
    def size = @entries.size
    def empty? = @entries.empty?
    def each(&) = @entries.each_value(&)

    def clear
      @mutex.synchronize { @entries.clear }
      @seed&.call(self)
      self
    end

    include Enumerable
  end
end
