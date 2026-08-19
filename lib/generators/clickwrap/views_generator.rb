# frozen_string_literal: true

require "rails/generators/base"

module Clickwrap
  module Generators
    # `rails generate clickwrap:views` — eject the engine's overridable templates
    # into the HOST app so they can be restyled. This is the Devise move
    # (`rails g devise:views`), and it works for the same boring Rails reason:
    # the host app's `app/views` sits AHEAD of any engine's view paths in the
    # lookup chain, so a file copied to e.g.
    # `app/views/clickwrap/captures/show.html.erb` SHADOWS the gem's bundled
    # default automatically — no config, no registration. Delete your copy and
    # the gem's default comes back. Upgrade the gem and your ejected copies are
    # untouched (re-run only if you WANT the new defaults).
    #
    # `source_root` points at the engine's own `app/views`, so `directory` copies
    # the exact templates the engine renders.
    #
    # One thing does not eject with the markup: the evidence contract. The
    # controls are initially unselected, the document links come before the
    # submit action, and the call to action recorded in the manifest is the one
    # the person can actually press. Restyle freely, but a copy that preselects a
    # control or moves the links below the button changes what the receipt is
    # describing — and the development linter will say so.
    #
    # The same goes for the composed line. `presentation.combined` is one control
    # answering several statements, and the manifest signs which ones; render it
    # and then iterate `presentation.itemized_statements`, never `statements`, or
    # the page offers a second control for a statement the one control already
    # covers. The linter reports that too.
    class ViewsGenerator < Rails::Generators::Base
      source_root File.expand_path("../../../app/views", __dir__)

      desc "Copy clickwrap's overridable views into your app so you can restyle them"

      class_option :views, type: :array,
                           desc: "Which view groups to copy (defaults to all of them)"

      def copy_views
        return say_nothing_to_copy if available_groups.empty?

        requested_groups.each do |group|
          unless available_groups.include?(group)
            say "   No `#{group}` views ship with this release. Available: " \
                "#{available_groups.join(", ")}.", :yellow
            next
          end

          directory "clickwrap/#{group}", "app/views/clickwrap/#{group}"
        end
      end

      def show_styling_tip
        return if available_groups.empty?

        say "\n🎨 Views copied — they are yours now, and the gem's originals stay put for"
        say "   reference. Tailwind, Bootstrap, ViewComponent, Phlex, and plain ERB all"
        say "   work; classes you add here are picked up by your build automatically,"
        say "   because the files now live in app/views."
        say "\n   Worth keeping while you restyle: explicit labels, visible keyboard focus,"
        say "   conventional high-contrast links, `aria-invalid`/`aria-describedby` error"
        say "   relationships, meaning that does not depend on color alone, and validation"
        say "   that still works with no JavaScript."
        say "\n   And keep the shape: render `presentation.combined` as ONE control, then"
        say "   iterate `presentation.itemized_statements` — never `statements`, or you offer"
        say "   a second box for a statement the first one already answers.\n"
      end

      private

      def requested_groups
        requested = Array(options[:views]).map(&:to_s).reject(&:empty?)
        requested.any? ? requested : available_groups
      end

      # Read from the engine rather than hardcoded, so this generator keeps
      # working as the engine's surfaces change and never offers a group that
      # does not exist.
      def available_groups
        @available_groups ||= begin
          root = File.join(self.class.source_root.to_s, "clickwrap")

          if File.directory?(root)
            Dir.children(root).select { |entry| File.directory?(File.join(root, entry)) }.sort
          else
            []
          end
        end
      end

      def say_nothing_to_copy
        say "\n   This release of clickwrap ships no ejectable views, so nothing was copied.", :yellow
        say "   `form.clickwrap` renders the controls and the submit action either way. For a"
        say "   fully custom surface, ask the presenter for primitives instead of recreating"
        say "   hidden inputs:"
        say "       presentation = Clickwrap.present(:signup, actor: current_user, ...)"
      end
    end
  end
end
