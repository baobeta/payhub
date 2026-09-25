# frozen_string_literal: true

# Fail at boot, not at the first request, if a role references a permission
# the catalogue does not define.
Rails.application.config.after_initialize { Permissions.validate! }
