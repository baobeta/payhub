class TieApiKeyModeToPrefix < ActiveRecord::Migration[8.1]
  # An sk_live_ key must open live data and an sk_test_ key test data; the
  # model already does this, the database now refuses anything else.
  def change
    add_check_constraint :api_keys,
                         "(livemode AND prefix = 'sk_live_') OR (NOT livemode AND prefix = 'sk_test_')",
                         name: "chk_api_keys_mode_matches_prefix"
  end
end
