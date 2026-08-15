# frozen_string_literal: true

require "erb"
require "cgi"

module Clickwrap
  # The human-readable projection of a receipt.
  #
  # Same facts as the canonical JSON, rendered for someone who has to read them
  # — a reviewer answering a complaint, an operator investigating a dispute, a
  # person asking what they agreed to. Never a different set of facts, and never
  # a stronger claim: where the JSON says a digest detects ordinary modification,
  # the HTML says that too, in a sentence.
  #
  # It is deliberately plain, self-contained HTML with no framework, no external
  # asset, and no JavaScript, because a receipt frequently ends up saved to disk,
  # attached to an email, or printed, and it has to still make sense there.
  class ReceiptHtml
    def initialize(receipt, reveal: [], view_context: nil)
      @receipt = receipt
      @reveal = reveal
      @view_context = view_context
      @body = receipt.to_h(reveal: reveal)
    end

    attr_reader :receipt, :reveal, :body

    def render
      ERB.new(TEMPLATE, trim_mode: "-").result(binding)
    end

    private

    def h(value) = CGI.escapeHTML(value.to_s)

    def acts = body["acts"] || []
    def documents = body["documents"] || []
    def presentation = body["presentation"] || {}
    def integrity = body["integrity"] || {}
    def retention = body["retention"] || {}
    def request_evidence = body["request_evidence"] || {}
    def lifecycle = body["lifecycle"] || {}
    def system_info = body["system"] || {}

    def kind_sentence(act)
      subject = h(act["assertion"])

      case act["kind"]
      when "agreement" then "Agreed to: #{subject}"
      when "acknowledgment" then "Acknowledged: #{subject}"
      when "consent" then act["action"] == "declined" ? "Declined: #{subject}" : "Consented to: #{subject}"
      when "declaration" then "Declared: #{subject}"
      when "attestation" then "Attested: #{subject}"
      when "authorization" then "Authorized: #{subject}"
      else "#{h(act['action'])}: #{subject}"
      end
    end

    # Each state gets a sentence rather than a bare word, because "blank" and
    # "deleted" and "we never collected this" mean completely different things
    # and a reader should not have to know the vocabulary to tell them apart.
    def request_evidence_sentence(category, fragment)
      name = category.tr("_", " ")

      case fragment["state"]
      when "not_configured"
        "No #{name} was recorded. This policy does not collect it."
      when "unavailable"
        "The #{name} could not be resolved (#{h(fragment['unavailable_reason'])}), so none was recorded."
      when "recorded"
        "The #{name} was recorded and is shown below."
      when "redacted_for_this_viewer"
        "A #{name} was recorded. It is not shown to this viewer."
      when "deleted_after_retention"
        "The #{name} was recorded and has since been deleted under the retention policy" \
          "#{fragment['deleted_at'] ? " on #{h(fragment['deleted_at'])}" : ''}."
      when "held"
        "A #{name} was recorded and is under a legal hold."
      else
        h(fragment["state"])
      end
    end

    TEMPLATE = <<~HTML
      <!DOCTYPE html>
      <html lang="en">
      <head>
        <meta charset="utf-8">
        <title>Clickwrap receipt <%= h(body["event_id"]) %></title>
        <style>
          body { font: 16px/1.55 system-ui, -apple-system, "Segoe UI", sans-serif; margin: 2rem auto;
                 max-width: 46rem; color: #14171a; padding: 0 1rem; }
          h1 { font-size: 1.4rem; margin-bottom: 0.2rem; }
          h2 { font-size: 1.05rem; margin: 2rem 0 0.5rem; border-bottom: 1px solid #d9dde1;
               padding-bottom: 0.3rem; }
          .subtle { color: #5b6570; font-size: 0.9rem; }
          dl { display: grid; grid-template-columns: 14rem 1fr; gap: 0.35rem 1rem; margin: 0; }
          dt { color: #5b6570; }
          dd { margin: 0; word-break: break-word; }
          code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.85em;
                 background: #f2f4f6; padding: 0.1em 0.35em; border-radius: 3px; }
          ul { padding-left: 1.2rem; }
          li { margin-bottom: 0.4rem; }
          .bounded { background: #f7f8f9; border-left: 3px solid #b6bec6; padding: 0.7rem 1rem;
                     margin: 1rem 0; font-size: 0.92rem; color: #3c4650; }
        </style>
      </head>
      <body>
        <h1>Evidence receipt</h1>
        <p class="subtle"><code><%= h(body["event_id"]) %></code> &middot;
          <%= h(body["event_type"]) %> &middot;
          recorded by the server at <%= h(body["recorded_at_by_server"]) %></p>

        <h2>What was done</h2>
        <ul>
        <% acts.each do |act| %>
          <li>
            <%= kind_sentence(act) %>
            <div class="subtle">
              <%= h(act["kind"]) %> &middot; <%= h(act["action"]) %>
              <% if act["expires_at"] %> &middot; valid until <%= h(act["expires_at"]) %><% end %>
              <% if act["one_time"] %> &middot; single use<% end %>
            </div>
          </li>
        <% end %>
        </ul>

        <h2>Exactly which documents</h2>
        <ul>
        <% documents.each do |document| %>
          <li><%= h(document["key"]) %> version <%= h(document["version"]) %>
            (<%= h(document["locale"]) %>)<br>
            <span class="subtle"><code><%= h(document["digest"]) %></code></span></li>
        <% end %>
        </ul>

        <h2>Who</h2>
        <dl>
          <dt>Actor reference</dt><dd><code><%= h(body.dig("actor", "reference")) %></code></dd>
          <dt>Attribution</dt><dd><%= h(body.dig("actor", "attribution", "method")) %></dd>
          <% if body.dig("actor", "tenant") %>
            <dt>Tenant</dt><dd><code><%= h(body.dig("actor", "tenant")) %></code></dd>
          <% end %>
          <% if body.dig("actor", "subject") %>
            <dt>Subject</dt><dd><code><%= h(body.dig("actor", "subject", "reference")) %></code></dd>
          <% end %>
        </dl>

        <% unless presentation.empty? %>
          <h2>What was on screen</h2>
          <dl>
            <dt>Call to action</dt><dd><%= h(presentation["submit_button_text"]) %></dd>
            <dt>Locale</dt><dd><%= h(presentation["locale"]) %></dd>
            <dt>Channel</dt><dd><%= h(presentation["capture_channel"]) %></dd>
            <dt>Offered at</dt><dd><%= h(presentation["offered_at"]) %></dd>
            <dt>Manifest digest</dt><dd><code><%= h(presentation["manifest_digest"]) %></code></dd>
          </dl>
          <p class="bounded"><%= h(presentation["proves"]) %></p>
        <% end %>

        <% if body["outcome"] %>
          <h2>What it authorized</h2>
          <dl>
          <% body["outcome"].each do |key, value| %>
            <dt><%= h(key.to_s.tr("_", " ")) %></dt><dd><%= h(value) %></dd>
          <% end %>
          </dl>
        <% end %>

        <h2>Request evidence</h2>
        <ul>
        <% request_evidence.each do |category, fragment| %>
          <li><%= request_evidence_sentence(category, fragment) %>
            <% if fragment["means"] %>
              <div class="subtle"><%= h(fragment["means"]) %></div>
            <% end %>
          </li>
        <% end %>
        </ul>

        <% if lifecycle["successors"]&.any? %>
          <h2>What happened afterwards</h2>
          <ul>
          <% lifecycle["successors"].each do |successor| %>
            <li><%= h(successor["event_type"]) %> at <%= h(successor["recorded_at_by_server"]) %>
              <% if successor["reason"] %><br><span class="subtle"><%= h(successor["reason"]) %></span><% end %>
            </li>
          <% end %>
          </ul>
        <% end %>

        <h2>Retention</h2>
        <dl>
          <dt>Retention class</dt><dd><%= h(retention["class"]) %></dd>
          <% if retention["core_event_retained_until"] %>
            <dt>Core event kept until</dt><dd><%= h(retention["core_event_retained_until"]) %></dd>
          <% end %>
          <% if retention["retention_rule"] %>
            <dt>Retention rule</dt><dd><%= h(retention["retention_rule"]) %> (resolved from host events)</dd>
          <% end %>
          <dt>Legal hold</dt><dd><%= retention["on_legal_hold"] ? "In effect" : "None" %></dd>
        </dl>

        <h2>Integrity</h2>
        <dl>
          <dt>Digest algorithm</dt><dd><%= h(integrity["digest_algorithm"]) %></dd>
          <dt>Event digest</dt><dd><code><%= h(integrity["event_digest"]) %></code></dd>
          <dt>Assurance tier</dt><dd><%= h(integrity["tier"]) %></dd>
        </dl>
        <p class="bounded"><%= h(integrity["detects"]) %></p>

        <h2>How to check this yourself</h2>
        <p class="subtle"><%= h(body["verifier_instructions"]) %></p>
        <dl>
          <dt>Receipt schema</dt><dd><%= h(body["schema"]) %></dd>
          <dt>Gem version</dt><dd><%= h(system_info["gem_version"]) %></dd>
          <dt>Application version</dt><dd><%= h(system_info["application_version"]) %></dd>
          <dt>Verifier version</dt><dd><%= h(system_info["verifier_version"]) %></dd>
        </dl>
      </body>
      </html>
    HTML
  end
end
