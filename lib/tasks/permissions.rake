# frozen_string_literal: true

# Files generated from Ruby for humans and for the Vue app. bin/check runs
# exports:all and fails if any of them changed, so they cannot drift.
namespace :permissions do
  desc "Write docs/permissions.md and app/frontend/shared/permissions.ts from app/lib/permissions.rb"
  task export: :environment do
    File.write(Rails.root.join("docs/permissions.md"), PermissionsExport.markdown)
    FileUtils.mkdir_p(Rails.root.join("app/frontend/shared"))
    File.write(Rails.root.join("app/frontend/shared/permissions.ts"), PermissionsExport.typescript)
    puts "Wrote docs/permissions.md and app/frontend/shared/permissions.ts"
  end
end

namespace :exports do
  desc "Write every generated file: permissions (docs + TS) and currency exponents (TS)"
  task all: ["permissions:export", :environment] do
    File.write(Rails.root.join("app/frontend/shared/currencies.ts"), CurrencyExport.typescript)
    puts "Wrote app/frontend/shared/currencies.ts"
  end
end
