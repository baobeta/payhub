# frozen_string_literal: true

require "rails_helper"

# Expected values live in spec/fixtures/permission_matrix.yml, written by hand.
# Changing who can do what therefore needs two edits: the catalogue and this
# file. The second edit is the reviewable diff.
#
# Examples are generated from the matrix at load time, so the loop variables
# are meant to be captured by the examples.
# rubocop:disable RSpec/LeakyLocalVariable
RSpec.describe "Permission matrix" do # rubocop:disable RSpec/DescribeClass
  matrix = YAML.load_file(Rails.root.join("spec/fixtures/permission_matrix.yml"))

  { "merchant" => Permissions::MERCHANT, "operator" => Permissions::OPERATOR }.each do |area, roles|
    area_permissions = Permissions::CATALOGUE.keys.select { |p| p.start_with?("ops.") == (area == "operator") }

    it "lists every #{area} permission, and nothing else" do
      expect(matrix.fetch(area).keys).to match_array(area_permissions)
    end

    area_permissions.each do |permission|
      it "states every #{area} role explicitly for #{permission}" do
        expect(matrix.fetch(area).fetch(permission).keys).to match_array(roles.keys)
      end

      roles.each_key do |role|
        expected = matrix.fetch(area).fetch(permission).fetch(role)
        it "#{area} #{role} #{expected ? 'may' : 'may not'} #{permission}" do
          expect(Permissions.granted?(area.to_sym, role, permission)).to eq(expected)
        end
      end
    end
  end
end
# rubocop:enable RSpec/LeakyLocalVariable
