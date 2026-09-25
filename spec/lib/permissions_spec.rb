# frozen_string_literal: true

require "rails_helper"

RSpec.describe Permissions do
  describe ".granted?" do
    it "grants a permission the role holds" do
      expect(described_class.granted?(:merchant, "support", "payments.refund")).to be(true)
    end

    it "denies a permission the role lacks" do
      expect(described_class.granted?(:merchant, "developer", "payments.refund")).to be(false)
    end

    it "raises on an unknown permission instead of silently denying" do
      expect { described_class.granted?(:merchant, "owner", "payments.refnud") }
        .to raise_error(Permissions::Unknown, /payments.refnud/)
    end

    it "raises on an unknown role" do
      expect { described_class.granted?(:merchant, "superuser", "payments.read") }
        .to raise_error(ArgumentError, /superuser/)
    end

    it "never grants operator permissions to merchant roles" do
      expect(described_class.granted?(:merchant, "owner", "ops.payments.read")).to be(false)
    end
  end

  describe ".validate!" do
    it "passes for the shipped catalogue" do
      expect { described_class.validate! }.not_to raise_error
    end

    it "keeps merchant and operator permissions in separate namespaces" do
      merchant = described_class::MERCHANT.values.reduce(Set.new, :|)
      operator = described_class::OPERATOR.values.reduce(Set.new, :|)
      expect(merchant.grep(/\Aops\./)).to be_empty
      expect(operator.reject { |p| p.start_with?("ops.") }).to be_empty
    end
  end

  describe "separation of duties" do
    it "gives no operator role both proposals.create and proposals.decide" do
      both = described_class::OPERATOR.select do |_role, perms|
        perms.include?("ops.proposals.create") && perms.include?("ops.proposals.decide")
      end
      expect(both.keys).to be_empty
    end

    it "does not let the operator admin decide proposals" do
      expect(described_class.granted?(:operator, "admin", "ops.proposals.decide")).to be(false)
    end
  end

  describe ".sensitive?" do
    it "marks money-moving and access-granting permissions as sensitive" do
      expect(described_class.sensitive?("payments.refund")).to be(true)
      expect(described_class.sensitive?("team.manage")).to be(true)
      expect(described_class.sensitive?("payments.read")).to be(false)
    end
  end
end
