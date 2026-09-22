class CreateFxRates < ActiveRecord::Migration[7.2]
  def change
    create_table :fx_rates, id: :uuid, default: -> { "uuid_generate_v7()" } do |t|
      t.string :base, limit: 3, null: false
      t.string :quote, limit: 3, null: false
      # The only decimal in the schema: a ratio, not an amount of money.
      t.decimal :rate, precision: 18, scale: 8, null: false
      t.datetime :captured_at, null: false

      t.datetime :created_at, null: false
    end

    # "Latest rate for this pair" lookup. Rates are never joined at read time —
    # the value is copied onto payments.fx_rate at creation.
    add_index :fx_rates, [:base, :quote, :captured_at],
              order: { captured_at: :desc }, name: "idx_fx_rates_latest"
  end
end
