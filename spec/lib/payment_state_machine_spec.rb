require "rails_helper"

RSpec.describe PaymentStateMachine do
  # The README's Mermaid diagram is the spec. Parse its edges so the code and
  # the documentation cannot silently drift apart.
  def edges_from_readme
    readme = Rails.root.join("README.md").read
    block = readme[/```mermaid\s*\nstateDiagram-v2(.*?)```/m, 1] or raise "no stateDiagram in README"
    block.scan(/^\s*(\w+)\s*-->\s*(\w+)/).reject { |from, _| from == "[*]" }
  end

  # Edges the diagram omits but the code adds on purpose. Each one must be
  # justified in DECISIONS.md. Keep this list in sync with that file.
  DELIBERATE_EXTRAS = [
    # ["unknown", "canceled"],
    # ["requires_action", "unknown"],
  ].freeze

  describe "TRANSITIONS" do
    it "has an entry for every state, so nothing falls through fetch's default" do
      expect(described_class::TRANSITIONS.keys.map(&:to_s)).to match_array(described_class::STATES)
    end

    it "only names real states as targets" do
      targets = described_class::TRANSITIONS.values.flatten.map(&:to_s).uniq
      expect(targets - described_class::STATES).to be_empty
    end

    it "contains every edge drawn in the README diagram" do
      missing = edges_from_readme.reject { |from, to| described_class.legal?(from, to) }
      expect(missing).to be_empty, "edges in README but not in TRANSITIONS: #{missing.inspect}"
    end

    it "contains no edges beyond the README diagram except the deliberate extras" do
      readme_edges = edges_from_readme.map { |from, to| [from, to] }
      coded_edges = described_class::TRANSITIONS.flat_map { |from, tos| tos.map { |to| [from.to_s, to.to_s] } }
      extra = coded_edges - readme_edges - DELIBERATE_EXTRAS
      expect(extra).to be_empty, "edges in TRANSITIONS but not in README (add to DELIBERATE_EXTRAS + DECISIONS.md if intended): #{extra.inspect}"
    end

    it "gives terminal states no outgoing edges" do
      described_class::TERMINAL.each do |s|
        expect(described_class::TRANSITIONS.fetch(s.to_sym, described_class::TRANSITIONS[s])).to be_empty
      end
    end
  end

  describe ".legal? / .assert_legal!" do
    it "accepts a drawn edge" do
      expect(described_class.legal?(:pending, :authorized)).to be true
      expect { described_class.assert_legal!("pending", "authorized") }.not_to raise_error
    end

    it "rejects the backwards edge that out-of-order webhooks would try" do
      expect(described_class.legal?(:captured, :authorized)).to be false
      expect { described_class.assert_legal!(:captured, :authorized) }
        .to raise_error(described_class::IllegalTransition, /captured -> authorized/)
    end

    it "rejects leaving a terminal state" do
      expect(described_class.legal?(:refunded, :captured)).to be false
    end
  end
end
