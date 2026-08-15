# frozen_string_literal: true

module Clickwrap
  module Services
    # Loads the host's document, policy, and retention declarations.
    #
    # They live in ordinary Ruby files — `config/clickwrap.rb` and
    # `config/clickwrap/*.rb` by default — because that makes them reviewable in
    # a pull request and deployable like the code they are. The engine re-reads
    # them through `to_prepare`, so a development reload picks up an edit the
    # same way it picks up a model change.
    #
    # Compilation happens here, at boot, and a mistake raises. A policy that
    # references a document nobody declared, a consent statement with no
    # withdrawal route, a one-time authorization with no expiry — each of those
    # is a bug that would otherwise be discovered by the first person who tried
    # to sign up, and each one gets a sentence explaining what to do about it.
    class LoadPolicies
      def initialize(paths: nil, root: nil)
        @paths = paths || Clickwrap.config.policy_paths
        @root = root || default_root
      end

      attr_reader :paths, :root

      def call
        files = resolve_files
        return [] if files.empty?

        reset_registries!
        files.each { |file| load_file(file) }
        files
      end

      def resolve_files
        return [] if root.nil?

        paths.flat_map { |pattern| Dir[File.join(root, pattern)] }.uniq.sort
      end

      private

      def default_root
        defined?(::Rails) && ::Rails.root ? ::Rails.root.to_s : nil
      end

      # A reload replaces the declarations rather than adding to them, so a
      # policy deleted from the file really is gone. Persisted evidence is
      # untouched: an event references the frozen revision it was captured
      # under, not whatever is in the registry today.
      def reset_registries!
        Clickwrap.documents.clear
        Clickwrap.policies.clear
        Clickwrap.retention_classes.clear
      end

      def load_file(file)
        load file
      rescue DefinitionError, ConfigurationError => e
        raise e.class, "#{e.message}\n\n  (while loading #{relative(file)})", e.backtrace
      end

      def relative(file)
        root ? file.delete_prefix("#{root}/") : file
      end
    end
  end
end
