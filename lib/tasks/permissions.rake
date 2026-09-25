# frozen_string_literal: true

namespace :permissions do
  desc "Write docs/permissions.md and app/frontend/shared/permissions.ts from app/lib/permissions.rb"
  task export: :environment do
    File.write(Rails.root.join("docs/permissions.md"), PermissionsExport.markdown)
    FileUtils.mkdir_p(Rails.root.join("app/frontend/shared"))
    File.write(Rails.root.join("app/frontend/shared/permissions.ts"), PermissionsExport.typescript)
    puts "Wrote docs/permissions.md and app/frontend/shared/permissions.ts"
  end
end
