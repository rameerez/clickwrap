# frozen_string_literal: true

module Clickwrap
  # A small thread-safe registry for compiled documents, policies, and retention
  # classes.
  #
  # Definitions are declared once at boot and read on every request, so writes
  # take a lock and reads do not. Re-registering the same key replaces the
  # definition, which is what makes `config.to_prepare` reloading work in
  # development: the file is re-evaluated and the new compiled definition wins.
  # Persisted evidence is unaffected — an event references the frozen policy
  # revision it was captured under, not whatever is in this registry today.
  class Registry
    def initialize(kind)
      @kind = kind
      @entries = {}
      @mutex = Mutex.new
    end

    attr_reader :kind

    def register(key, definition)
      @mutex.synchronize { @entries[key] = definition }
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
    def clear = @mutex.synchronize { @entries.clear }

    include Enumerable
  end
end
