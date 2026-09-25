# PayHub UI Phase 1: Merchant Dashboard Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Merchant users can be invited, sign in with a password and a TOTP code, and use every merchant page in design §4: home, payments (list, export, detail with capture, cancel and refund), balance and settlements, API keys, webhooks and events, test/live mode, team, security history and profile.

**Architecture:** One polymorphic `sessions` table and a shared `TwoFactorPrincipal` concern carry login for merchant users now and operators in Phase 2. `Dashboard::Api::BaseController < Web::BaseController` authenticates from a signed, path-scoped cookie, picks the live merchant or its test twin from the session's mode, and declares a permission on every action. Money-moving POSTs run through the same `IdempotencyGuard` and services as `/v1`. The Vue app (`merchant.ts`) uses Vue Router, TanStack Vue Query and Reka UI. It hides what the role cannot do, and the server enforces everything.

**Tech Stack:** Rails 8.1, Postgres 16, Sorbet, RSpec, `bcrypt` (has_secure_password), `rotp` (TOTP), `rqrcode` (QR SVG), Active Record encryption, Action Mailer and MailCatcher, Vue 3 + TypeScript, Vue Router, @tanstack/vue-query, reka-ui, Tailwind 4, Vitest, Playwright.

**Design sources:** [UI design](2026-09-25-ui-design.md) §1 to §7, [use cases](2026-09-25-ui-use-cases.md) A-01 to A-07 and M-01 to M-22, [foundation plan](2026-09-25-ui-foundation.md) (already merged: permissions, audit log, api_keys, twins, `Web::BaseController`, Vite shells).

---

## Conventions (carried over from Phase 0, plus lessons from executing it)

- Every Ruby file starts with `# typed: true` (or `strict` where the neighbours are) and `# frozen_string_literal: true`. Controller concerns that use the controller API are `# typed: false` with a comment saying why (Sorbet cannot see `request` or `before_action` inside `ActiveSupport::Concern`). Precedent: `app/controllers/concerns/authorization.rb`.
- Migrations: `ActiveRecord::Migration[8.1]`, UUID v7 keys, `up`/`down`. Run `bin/rails db:migrate && RAILS_ENV=test bin/rails db:migrate`, then re-dump from **development** (`bin/rails db:schema:dump`) before committing `db/structure.sql`. A dump taken from the test DB rewrites every CHECK constraint's formatting.
- After adding a model or gem: `bin/tapioca dsl`, `bin/tapioca gem <name>`. Commit only the RBIs you need. `bin/tapioca gem` with no arguments regenerates dozens of unrelated gems; delete those.
- In `typed: true` controllers, `rescue_from … do … end` blocks need `T.bind(self, <ControllerClass>)` as their first line (see `V1::BaseController`); Sorbet otherwise types `self` as the class. Macros from `typed: false` concerns (`requires_permission`, `idempotent`) type-check once `bin/tapioca dsl` has generated their RBI.
- Request specs need `type: :request` (the helpers are included only for that type).
- Test env has `allow_forgery_protection = false`. A spec that checks CSRF must set `ActionController::Base.allow_forgery_protection = true` and restore it in `ensure`.
- Spec files are named after the class they describe (`RSpec/SpecFilePathFormat`); string describes need `# rubocop:disable RSpec/DescribeClass` on that line.
- Gate every commit on the real exit code: `bin/check && git commit …`. Never pipe `bin/check` into `tail`, which hides its exit status.
- `bin/check` is the gate. Commit after every task on the feature branch.
- Steps marked **USER WRITES** are for the user. Stop, show the prepared file and guidance, and continue once they have written it.

---

### Task 0: Branch

```bash
git checkout master && git pull
git checkout -b feature/ui-phase-1-merchant
```

If Phase 0 is not merged yet, branch from `feature/ui-foundation` instead and rebase later.

---

### Task 1: Gems and encryption keys

**Files:**
- Modify: `Gemfile`
- Create: `config/initializers/active_record_encryption.rb`
- Test: `spec/lib/active_record_encryption_config_spec.rb`

**Step 1: Add gems**

```bash
bundle add bcrypt --version "~> 3.1"
bundle add rotp --version "~> 6.3"
bundle add rqrcode --version "~> 2.2"
bin/tapioca gem bcrypt rotp rqrcode rqrcode_core chunky_png
```

**Step 2: Write the failing test**

```ruby
# spec/lib/active_record_encryption_config_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Active Record encryption" do # rubocop:disable RSpec/DescribeClass
  it "is configured, so encrypted columns can be read and written" do
    config = ActiveRecord::Encryption.config
    expect([config.primary_key, config.deterministic_key, config.key_derivation_salt]).to all(be_present)
  end
end
```

Run: `bundle exec rspec spec/lib/active_record_encryption_config_spec.rb`
Expected: FAIL (keys are nil).

**Step 3: Configure keys from the environment, with fixed dev/test defaults**

```ruby
# config/initializers/active_record_encryption.rb
# frozen_string_literal: true

# Encrypts TOTP secrets at rest (merchant_users.otp_secret, operators.otp_secret).
# Production must set all three variables; `bin/rails db:encryption:init`
# prints fresh values. Dev and test use fixed values so fixtures and seeds
# stay readable across machines. They protect nothing and must never be reused.
keys = {
  primary_key: ENV["AR_ENCRYPTION_PRIMARY_KEY"],
  deterministic_key: ENV["AR_ENCRYPTION_DETERMINISTIC_KEY"],
  key_derivation_salt: ENV["AR_ENCRYPTION_KEY_DERIVATION_SALT"]
}

if keys.values.any?(&:blank?)
  raise "Set AR_ENCRYPTION_* environment variables (bin/rails db:encryption:init)" if Rails.env.production?

  keys = {
    primary_key: "dev-only-primary-key-payhub-0000000000",
    deterministic_key: "dev-only-deterministic-key-payhub-00000",
    key_derivation_salt: "dev-only-key-derivation-salt-payhub-000"
  }
end

Rails.application.config.active_record.encryption.primary_key = keys[:primary_key]
Rails.application.config.active_record.encryption.deterministic_key = keys[:deterministic_key]
Rails.application.config.active_record.encryption.key_derivation_salt = keys[:key_derivation_salt]
```

Run the spec again. Expected: PASS. If it still fails, the initializer ran after Active Record read its config; move the assignments into `config/application.rb` inside the `Application` class as `config.active_record.encryption.primary_key = …`.

**Step 4: Commit**

```bash
bin/check && git add Gemfile Gemfile.lock config/initializers/active_record_encryption.rb \
  spec/lib/active_record_encryption_config_spec.rb sorbet/rbi/gems && \
  git commit -m "Add bcrypt, rotp, rqrcode and Active Record encryption keys"
```

---

### Task 2: merchant_users, sessions and recovery_codes

**Files:**
- Create: `db/migrate/20260926000001_create_merchant_users_and_sessions.rb`
- Create: `app/models/concerns/two_factor_principal.rb`, `app/models/merchant_user.rb`, `app/models/session.rb`, `app/models/recovery_code.rb`
- Modify: `app/models/merchant.rb` (`has_many :merchant_users`)
- Test: `spec/models/merchant_user_spec.rb`, `spec/models/session_spec.rb`, `spec/models/recovery_code_spec.rb`, `spec/factories/merchant_users.rb`

**Step 1: Write the failing tests**

```ruby
# spec/factories/merchant_users.rb
# frozen_string_literal: true

FactoryBot.define do
  factory :merchant_user do
    merchant
    sequence(:email) { |n| "user#{n}@example.com" }
    name { "Sam" }
    role { "admin" }
    password { "correct horse battery staple" }
    accepted_at { Time.current }
    otp_secret { ROTP::Base32.random }
    otp_enabled_at { Time.current }

    trait :invited do
      password { nil }
      accepted_at { nil }
      otp_enabled_at { nil }
    end
  end
end
```

```ruby
# spec/models/merchant_user_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe MerchantUser do
  let(:merchant) { create(:merchant) }

  it "allows exactly one active owner per merchant" do
    create(:merchant_user, merchant:, role: "owner")
    expect { create(:merchant_user, merchant:, role: "owner") }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "rejects an unknown role in the database, not only in the model" do
    user = create(:merchant_user, merchant:)
    expect { described_class.where(id: user.id).update_all(role: "superuser") }
      .to raise_error(ActiveRecord::StatementInvalid, /chk_merchant_users_role/)
  end

  it "belongs only to a live merchant" do
    expect(build(:merchant_user, merchant: merchant.test_twin!)).not_to be_valid
  end

  it "treats emails case-insensitively" do
    create(:merchant_user, email: "Sam@Example.com")
    expect { create(:merchant_user, email: "sam@example.com") }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "stores the TOTP secret encrypted" do
    user = create(:merchant_user, otp_secret: "JBSWY3DPEHPK3PXP")
    raw = described_class.connection.select_value("SELECT otp_secret FROM merchant_users WHERE id = '#{user.id}'")
    expect(raw).not_to include("JBSWY3DPEHPK3PXP")
    expect(user.reload.otp_secret).to eq("JBSWY3DPEHPK3PXP")
  end

  describe "#verify_otp!" do
    let(:user) { create(:merchant_user) }
    let(:code) { ROTP::TOTP.new(user.otp_secret).now }

    it "accepts the current code once, then refuses it as a replay" do
      expect(user.verify_otp!(code)).to be(true)
      expect(user.verify_otp!(code)).to be(false)
    end

    it "refuses a malformed code without raising" do
      expect(user.verify_otp!("12ab56")).to be(false)
    end
  end

  describe "lockout" do
    let(:user) { create(:merchant_user) }

    it "locks for 30 minutes after 10 failures" do
      10.times { user.register_failure! }
      expect(user).to be_locked
      travel 31.minutes
      expect(user).not_to be_locked
    end

    it "resets the counter on success" do
      3.times { user.register_failure! }
      user.reset_failures!
      expect(user.reload.failed_attempts).to eq(0)
    end
  end

  describe ".invite!" do
    it "returns a raw token and stores only its digest, valid for 10 days" do
      user, token = described_class.invite!(merchant:, email: "new@example.com", role: "support", invited_by: nil)
      expect(user.invitation_digest).to eq(Digest::SHA256.hexdigest(token))
      expect(described_class.find_by_invitation_token(token)).to eq(user)
      travel 11.days
      expect(described_class.find_by_invitation_token(token)).to be_nil
    end

    it "never invites an owner" do
      expect { described_class.invite!(merchant:, email: "x@example.com", role: "owner", invited_by: nil) }
        .to raise_error(ArgumentError, /owner/)
    end
  end
end
```

```ruby
# spec/models/session_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Session do
  let(:user) { create(:merchant_user) }
  let(:session) { described_class.create!(principal: user, ip: "10.0.0.1", user_agent: "rspec") }

  it "expires after the idle timeout" do
    expect(session.active?(idle: 15.minutes)).to be(true)
    travel 16.minutes
    expect(session.active?(idle: 15.minutes)).to be(false)
  end

  it "expires 12 hours after sign-in however active it is" do
    travel 11.hours
    session.touch_activity!
    travel 2.hours
    expect(session.active?(idle: 15.minutes)).to be(false)
  end

  it "records activity at most once a minute" do
    freeze_time do
      session.touch_activity!
      travel 30.seconds
      session.touch_activity!
      expect(session.reload.last_active_at).to eq(30.seconds.ago)
    end
  end

  it "stays stepped up for 10 minutes" do
    session.update!(stepped_up_at: Time.current)
    travel 9.minutes
    expect(session.stepped_up?).to be(true)
    travel 2.minutes
    expect(session.stepped_up?).to be(false)
  end

  it "is inactive once revoked" do
    session.revoke!
    expect(session.active?(idle: 15.minutes)).to be(false)
  end
end
```

```ruby
# spec/models/recovery_code_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe RecoveryCode do
  let(:user) { create(:merchant_user) }

  it "issues 10 codes, stores digests, and replaces the old set" do
    first = described_class.regenerate!(user)
    second = described_class.regenerate!(user)
    expect(second.size).to eq(10)
    expect(described_class.where(principal: user).count).to eq(10)
    expect(described_class.consume!(user, first.first)).to be(false)
  end

  it "accepts each code once, ignoring case and dashes" do
    codes = described_class.regenerate!(user)
    expect(described_class.consume!(user, codes.first.upcase)).to be(true)
    expect(described_class.consume!(user, codes.first)).to be(false)
  end
end
```

Run: `bundle exec rspec spec/models/merchant_user_spec.rb spec/models/session_spec.rb spec/models/recovery_code_spec.rb`
Expected: FAIL with `uninitialized constant MerchantUser`.

**Step 2: Migration**

```ruby
# db/migrate/20260926000001_create_merchant_users_and_sessions.rb
class CreateMerchantUsersAndSessions < ActiveRecord::Migration[8.1]
  def up
    create_table :merchant_users, id: :uuid, default: -> { "uuid_generate_v7()" } do |t|
      t.references :merchant, type: :uuid, null: false, foreign_key: true
      t.string :email, null: false
      t.string :name
      t.string :password_digest              # NULL until the invitation is accepted
      t.string :role, null: false
      t.text :otp_secret                     # encrypted by Active Record
      t.datetime :otp_enabled_at
      t.bigint :otp_last_used_step           # TOTP replay guard
      t.integer :failed_attempts, null: false, default: 0
      t.datetime :locked_until
      t.uuid :invited_by_id
      t.string :invitation_digest
      t.datetime :invitation_expires_at
      t.datetime :accepted_at
      t.datetime :disabled_at
      t.timestamps
    end
    add_index :merchant_users, "lower(email)", unique: true, name: "idx_merchant_users_email"
    add_index :merchant_users, :invitation_digest, unique: true, where: "invitation_digest IS NOT NULL"
    add_index :merchant_users, :merchant_id, unique: true, where: "role = 'owner' AND disabled_at IS NULL",
                                             name: "idx_merchant_users_one_owner"
    add_check_constraint :merchant_users, "role IN ('owner', 'admin', 'developer', 'support', 'viewer')",
                         name: "chk_merchant_users_role"
    add_foreign_key :merchant_users, :merchant_users, column: :invited_by_id
    add_foreign_key :api_keys, :merchant_users, column: :created_by_id

    # Polymorphic so operators (phase 2) share it. Never deleted: revoked_at
    # ends a session, and the rows are evidence for the security history.
    create_table :sessions, id: :uuid, default: -> { "uuid_generate_v7()" } do |t|
      t.string :principal_type, null: false
      t.uuid :principal_id, null: false
      t.string :ip
      t.string :user_agent
      t.boolean :livemode, null: false, default: true
      t.datetime :last_active_at, null: false
      t.datetime :stepped_up_at
      t.datetime :revoked_at
      t.timestamps
    end
    add_index :sessions, %i[principal_type principal_id created_at]
    add_check_constraint :sessions, "principal_type IN ('MerchantUser', 'Operator')", name: "chk_sessions_principal_type"

    create_table :recovery_codes, id: :uuid, default: -> { "uuid_generate_v7()" } do |t|
      t.string :principal_type, null: false
      t.uuid :principal_id, null: false
      t.string :code_digest, null: false
      t.datetime :used_at
      t.datetime :created_at, null: false
    end
    add_index :recovery_codes, %i[principal_type principal_id]
    add_index :recovery_codes, :code_digest, unique: true
  end

  def down
    drop_table :recovery_codes
    drop_table :sessions
    remove_foreign_key :api_keys, column: :created_by_id
    drop_table :merchant_users
  end
end
```

**Step 3: Models**

```ruby
# app/models/concerns/two_factor_principal.rb
# typed: false
# frozen_string_literal: true

# Password + TOTP login shared by MerchantUser and (phase 2) Operator.
# typed: false: has_secure_password and encrypts are class macros Sorbet
# cannot see from inside a concern; the model specs cover this module.
module TwoFactorPrincipal
  extend ActiveSupport::Concern

  MAX_FAILURES = 10
  LOCK_FOR = 30.minutes
  MIN_PASSWORD_LENGTH = 12

  included do
    has_secure_password validations: false
    encrypts :otp_secret

    has_many :sessions, as: :principal, dependent: :restrict_with_exception
    has_many :recovery_codes, as: :principal, dependent: :restrict_with_exception

    validates :password, length: { minimum: MIN_PASSWORD_LENGTH }, allow_nil: true
    before_validation { self.email = email.to_s.strip.downcase }

    scope :active, -> { where(disabled_at: nil) }
  end

  def active? = disabled_at.nil?
  def otp_enabled? = otp_enabled_at.present?
  def locked? = locked_until.present? && locked_until.future?

  # True once per valid code: the matched time step must be newer than the
  # last one used, so a code read off a shoulder cannot be replayed.
  def verify_otp!(code)
    step = Otp.verify(otp_secret, code, after_step: otp_last_used_step)
    return false unless step

    update_columns(otp_last_used_step: step, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
    true
  end

  def register_failure!
    attempts = failed_attempts + 1
    update_columns(failed_attempts: attempts, # rubocop:disable Rails/SkipsModelValidations
                   locked_until: attempts >= MAX_FAILURES ? LOCK_FOR.from_now : locked_until)
  end

  def reset_failures!
    update_columns(failed_attempts: 0, locked_until: nil) # rubocop:disable Rails/SkipsModelValidations
  end

  def revoke_sessions!
    sessions.where(revoked_at: nil).update_all(revoked_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
  end
end
```

```ruby
# app/lib/otp.rb
# typed: strict
# frozen_string_literal: true

# TOTP (RFC 6238) via rotp: 6 digits, 30-second steps, one step of drift.
module Otp
  extend T::Sig

  ISSUER = "PayHub"
  DRIFT_SECONDS = 30

  sig { returns(String) }
  def self.generate_secret = ROTP::Base32.random

  sig { params(secret: String, email: String).returns(String) }
  def self.provisioning_uri(secret, email) = ROTP::TOTP.new(secret, issuer: ISSUER).provisioning_uri(email)

  sig { params(uri: String).returns(String) }
  def self.qr_svg(uri) = RQRCode::QRCode.new(uri).as_svg(module_size: 4, use_path: true, viewbox: true)

  # The matched time step, or nil. Codes at or before `after_step` are refused.
  sig { params(secret: T.nilable(String), code: T.untyped, after_step: T.nilable(Integer)).returns(T.nilable(Integer)) }
  def self.verify(secret, code, after_step: nil)
    return nil if secret.blank? || !code.to_s.match?(/\A\d{6}\z/)

    totp = ROTP::TOTP.new(secret)
    at = totp.verify(code.to_s, drift_behind: DRIFT_SECONDS, drift_ahead: DRIFT_SECONDS,
                                after: after_step && (after_step * totp.interval))
    at && (at / totp.interval)
  end
end
```

```ruby
# app/models/merchant_user.rb
# typed: true
# frozen_string_literal: true

# A person on a merchant's team. Belongs to the LIVE merchant; the session's
# mode decides whether they read live data or the test twin's (design §2).
class MerchantUser < ApplicationRecord
  include TwoFactorPrincipal

  ROLES = %w[owner admin developer support viewer].freeze
  INVITABLE_ROLES = (ROLES - %w[owner]).freeze
  INVITATION_TTL = 10.days

  belongs_to :merchant
  belongs_to :invited_by, class_name: "MerchantUser", optional: true

  validates :role, inclusion: { in: ROLES }
  validate :merchant_is_live

  # Returns [user, raw_token]. The token goes into the email link only.
  def self.invite!(merchant:, email:, role:, invited_by:)
    raise ArgumentError, "owner cannot be invited; use ownership transfer" unless INVITABLE_ROLES.include?(role)

    token = SecureRandom.urlsafe_base64(32)
    user = create!(merchant:, email:, role:, invited_by:, invitation_digest: Digest::SHA256.hexdigest(token),
                   invitation_expires_at: INVITATION_TTL.from_now, otp_secret: Otp.generate_secret)
    [user, token]
  end

  def self.find_by_invitation_token(token)
    return nil if token.blank?

    where(accepted_at: nil, disabled_at: nil).where("invitation_expires_at > ?", Time.current)
                                              .find_by(invitation_digest: Digest::SHA256.hexdigest(token))
  end

  def pending_invitation? = accepted_at.nil?

  private

  def merchant_is_live
    errors.add(:merchant, "must be the live merchant") unless merchant&.livemode
  end
end
```

```ruby
# app/models/session.rb
# typed: true
# frozen_string_literal: true

# One signed-in browser. The cookie holds only the id (signed); everything
# else is here, so revoking a row signs that browser out everywhere.
class Session < ApplicationRecord
  ABSOLUTE_LIFETIME = 12.hours
  STEP_UP_WINDOW = 10.minutes
  ACTIVITY_RESOLUTION = 1.minute

  belongs_to :principal, polymorphic: true

  before_validation { self.last_active_at ||= Time.current }

  def active?(idle:)
    revoked_at.nil? && last_active_at > idle.ago && created_at > ABSOLUTE_LIFETIME.ago
  end

  def touch_activity!
    last = last_active_at
    return if last && last > ACTIVITY_RESOLUTION.ago

    update_column(:last_active_at, Time.current) # rubocop:disable Rails/SkipsModelValidations
  end

  def stepped_up?
    at = stepped_up_at
    !at.nil? && at > STEP_UP_WINDOW.ago
  end

  def step_up! = update!(stepped_up_at: Time.current)
  def revoke! = update!(revoked_at: Time.current)
end
```

```ruby
# app/models/recovery_code.rb
# typed: true
# frozen_string_literal: true

# Ten single-use codes, shown once. Stored as SHA-256 digests: each has 50
# random bits, so a slow hash adds nothing but latency.
class RecoveryCode < ApplicationRecord
  COUNT = 10

  belongs_to :principal, polymorphic: true

  def self.normalize(raw) = raw.to_s.downcase.delete("^a-z0-9")

  # Returns the raw codes, formatted xxxxx-xxxxx.
  def self.regenerate!(principal)
    codes = Array.new(COUNT) { SecureRandom.alphanumeric(10).downcase.insert(5, "-") }
    transaction do
      where(principal:).delete_all
      codes.each { |c| create!(principal:, code_digest: Digest::SHA256.hexdigest(normalize(c))) }
    end
    codes
  end

  def self.consume!(principal, raw)
    digest = Digest::SHA256.hexdigest(normalize(raw))
    where(principal:, used_at: nil, code_digest: digest).update_all(used_at: Time.current) == 1 # rubocop:disable Rails/SkipsModelValidations
  end
end
```

Add to `app/models/merchant.rb`, after `has_many :api_keys`:

```ruby
  has_many :merchant_users, dependent: :restrict_with_exception
```

**Step 4: Migrate and run**

Run: `bin/rails db:migrate && RAILS_ENV=test bin/rails db:migrate && bundle exec rspec spec/models`
Expected: PASS.

**Step 5: Commit**

```bash
bin/rails db:schema:dump && bin/tapioca dsl
bin/check && git add db/migrate db/structure.sql app/models app/lib/otp.rb spec/models spec/factories sorbet/rbi && \
  git commit -m "Add merchant users, sessions and recovery codes with TOTP, lockout and one owner per merchant"
```

---

### Task 3: SignIn service

**Files:**
- Create: `app/services/sign_in.rb`
- Test: `spec/services/sign_in_spec.rb`

**Step 1: Write the failing test**

```ruby
# spec/services/sign_in_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe SignIn do
  let!(:user) { create(:merchant_user, email: "sam@example.com") }

  it "accepts the right password" do
    expect(described_class.password(MerchantUser, email: "SAM@example.com", password: "correct horse battery staple"))
      .to have_attributes(status: :ok, principal: user)
  end

  it "answers an unknown email exactly like a wrong password" do
    unknown = described_class.password(MerchantUser, email: "nobody@example.com", password: "x" * 12)
    wrong = described_class.password(MerchantUser, email: "sam@example.com", password: "x" * 12)
    expect([unknown.status, wrong.status]).to eq(%i[invalid invalid])
  end

  it "locks after 10 wrong passwords and then refuses even the right one" do
    10.times { described_class.password(MerchantUser, email: "sam@example.com", password: "x" * 12) }
    expect(described_class.password(MerchantUser, email: "sam@example.com", password: "correct horse battery staple"))
      .to have_attributes(status: :locked)
  end

  it "refuses a disabled user and an invitation that was never accepted" do
    user.update!(disabled_at: Time.current)
    invited, _token = MerchantUser.invite!(merchant: user.merchant, email: "new@example.com", role: "viewer", invited_by: nil)
    expect(described_class.password(MerchantUser, email: "sam@example.com", password: "correct horse battery staple").status).to eq(:invalid)
    expect(described_class.password(MerchantUser, email: invited.email, password: "anything-long-enough").status).to eq(:invalid)
  end
end
```

Run: `bundle exec rspec spec/services/sign_in_spec.rb`
Expected: FAIL with `uninitialized constant SignIn`.

**Step 2: Implement**

```ruby
# app/services/sign_in.rb
# typed: true
# frozen_string_literal: true

# First factor. Works for any TwoFactorPrincipal model (MerchantUser now,
# Operator in phase 2). The second factor is checked by the caller.
class SignIn
  Result = Struct.new(:status, :principal, keyword_init: true)

  # Compared against when the email is unknown, so both paths cost one bcrypt.
  DUMMY_DIGEST = BCrypt::Password.create("payhub-dummy-password").to_s.freeze

  def self.password(scope, email:, password:)
    principal = scope.active.where.not(accepted_at: nil).find_by("lower(email) = ?", email.to_s.strip.downcase)
    unless principal&.password_digest
      BCrypt::Password.new(DUMMY_DIGEST).is_password?(password.to_s)
      return Result.new(status: :invalid, principal: nil)
    end
    return Result.new(status: :locked, principal:) if principal.locked?

    if principal.authenticate(password.to_s)
      Result.new(status: :ok, principal:)
    else
      principal.register_failure!
      Result.new(status: principal.locked? ? :locked : :invalid, principal: nil)
    end
  end
end
```

The `accepted_at` filter is merchant-specific; in Phase 2, operators get the same column so the scope works unchanged.

**Step 3: Run and commit**

Run: `bundle exec rspec spec/services/sign_in_spec.rb`
Expected: PASS.

```bash
bin/check && git add app/services/sign_in.rb spec/services/sign_in_spec.rb && \
  git commit -m "Add a principal-agnostic password check with lockout and no email enumeration"
```

---

### Task 4: Authorization: 401 first, step-up for sensitive permissions, audited unknown roles

**Files:**
- Modify: `app/controllers/concerns/authorization.rb`, `app/lib/api_error.rb`
- Modify: `spec/controllers/web/base_controller_authorization_spec.rb`

Four changes, all from the Phase 0 review or design §3 layer 5:
1. No principal means **401 before any audit row**, so anonymous traffic cannot flood the append-only table.
2. A **sensitive** permission also needs a fresh step-up: **401 `step_up_required`**.
3. An unknown role string is a **denial** (403, audited), not a 500.
4. The grant check goes through an overridable `permission_granted?` so Phase 2's read-only impersonation can narrow it.

**Step 1: Update the spec first**

In the anonymous controller in `spec/controllers/web/base_controller_authorization_spec.rb`, add:

```ruby
    def step_up_fresh? = request.headers["X-Test-Stepped-Up"] == "1"
```

Change the "allows a role that holds the permission" example to set `request.headers["X-Test-Stepped-Up"] = "1"`, and add:

```ruby
  it "answers 401 without an audit row when nobody is signed in" do
    expect { post :create }.not_to change(AuditEvent, :count)
    expect(response).to have_http_status(:unauthorized)
  end

  it "asks for step-up before a sensitive permission" do
    request.headers["X-Test-Role"] = "support"
    post :create
    expect(response).to have_http_status(:unauthorized)
    expect(JSON.parse(response.body).dig("error", "code")).to eq("step_up_required")
  end

  it "does not ask for step-up on a non-sensitive permission" do
    request.headers["X-Test-Role"] = "viewer"
    get :index
    expect(response).to have_http_status(:ok)
  end

  it "denies and audits an unknown role instead of failing with 500" do
    request.headers["X-Test-Role"] = "superuser"
    expect { get :index }.to change(AuditEvent, :count).by(1)
    expect(response).to have_http_status(:forbidden)
  end
```

Run: `bundle exec rspec spec/controllers/web`
Expected: the new examples FAIL.

**Step 2: ApiError helpers**

In `app/lib/api_error.rb`, next to `self.forbidden`:

```ruby
  sig { params(code: String, message: String).returns(ApiError) }
  def self.unauthenticated(code: "unauthenticated", message: "Sign in to continue")
    new(type: Type::InvalidRequest, http_status: 401, code:, message:)
  end

  sig { returns(ApiError) }
  def self.step_up_required
    new(type: Type::InvalidRequest, http_status: 401, code: "step_up_required",
        message: "Confirm with your authenticator code to continue")
  end

  sig { params(until_time: ActiveSupport::TimeWithZone).returns(ApiError) }
  def self.locked(until_time)
    new(type: Type::InvalidRequest, http_status: 423, code: "account_locked",
        message: "Too many attempts. Try again after #{until_time.utc.iso8601}",
        details: { "locked_until" => until_time.utc.iso8601 })
  end
```

Check `ApiError#initialize` accepts `details:` (it does: `details: {}`) and that `to_h` includes it; if not, add `"details" => details` to `to_h` only when non-empty.

**Step 3: Concern**

Replace `authorize!` in `app/controllers/concerns/authorization.rb`, and add the hooks:

```ruby
  def authorize!(permission)
    @authorization_checked = true
    raise ApiError.unauthenticated if authorization_role.nil?

    unless permission_granted?(permission)
      record_denial(permission)
      raise ApiError.forbidden(permission)
    end
    raise ApiError.step_up_required if Permissions.sensitive?(permission) && !step_up_fresh?
  end

  # Phase 2 narrows this for read-only impersonation.
  def permission_granted?(permission)
    Permissions.granted?(authorization_area, authorization_role, permission)
  rescue ArgumentError => e
    raise if e.is_a?(Permissions::Unknown) # a typo in code is a bug, not a denial

    false # unknown role: deny (and audit), never 500
  end

  # Fail closed: only an area base controller that tracks step-up says yes.
  def step_up_fresh? = false
```

**Step 4: Run and commit**

Run: `bundle exec rspec spec/controllers/web spec/routing`
Expected: PASS.

```bash
bin/check && git add app/controllers/concerns/authorization.rb app/lib/api_error.rb spec/controllers && \
  git commit -m "Authorization: 401 before audit, step-up for sensitive permissions, deny unknown roles"
```

---

### Task 5: Shared idempotency for UI writes

**Files:**
- Create: `app/controllers/concerns/idempotent_action.rb`
- Modify: `app/controllers/v1/base_controller.rb` (use the concern; behaviour unchanged)
- Test: existing `spec/requests/v1/idempotency_spec.rb` (regression), new example in Task 10

**Step 1: Extract the concern**

Move the body of `V1::BaseController#with_idempotency` into a concern that both areas use, parameterised by the merchant and key.

```ruby
# app/controllers/concerns/idempotent_action.rb
# typed: false
# frozen_string_literal: true

# Runs a POST at most once per (merchant, key) and replays the stored answer
# (DECISIONS #3). Used by /v1 and by the UI's money-moving actions.
# typed: false: uses the controller API (request, response, render).
module IdempotentAction
  extend ActiveSupport::Concern

  class_methods do
    # Declare AFTER requires_permission: callbacks run in declaration order,
    # so a denied request never opens the guard's claim (design §3).
    def idempotent(only:)
      around_action :run_idempotently, only:
    end
  end

  private

  def idempotency_merchant = current_merchant
  def idempotency_key = request.headers["Idempotency-Key"].to_s

  def run_idempotently(&action)
    if idempotency_key.empty?
      raise ApiError.invalid_request("Idempotency-Key header is required", param: "Idempotency-Key",
                                                                          code: "missing_idempotency_key")
    end

    guard = IdempotencyGuard.new(merchant: idempotency_merchant, key: idempotency_key,
                                 request_method: request.request_method, path: request.path, raw_body: request.raw_post)
    outcome = guard.call do
      begin
        action.call
      rescue ApiError => e
        render_api_error(e) # rescue_from runs outside around_action; store the error answer
      end
      [response.status, JSON.parse(response.body)]
    end
    return unless outcome.replayed

    response.set_header("Idempotent-Replayed", "true")
    render json: outcome.body, status: outcome.status
  end
end
```

In `V1::BaseController`: `include IdempotentAction`, keep `require_idempotency_key!` as is, replace the `around_action :with_idempotency, if: …` with `around_action :run_idempotently, if: -> { request.post? }` (keep the `T.bind`), and delete `with_idempotency`.

**Step 2: Regression**

Run: `bundle exec rspec spec/requests/v1 spec/services/idempotency_guard_spec.rb`
Expected: PASS, unchanged.

**Step 3: Commit**

```bash
bin/check && git add app/controllers && \
  git commit -m "Share the idempotency around_action between /v1 and the UI"
```

---

### Task 6: Dashboard::Api::BaseController

**Files:**
- Create: `app/controllers/dashboard/api/base_controller.rb`, `app/controllers/dashboard/api/me_controller.rb`
- Modify: `config/routes.rb`, `app/controllers/web/base_controller.rb` (log payload)
- Test: `spec/requests/dashboard/api/me_spec.rb`, `spec/support/dashboard_helpers.rb`

**Step 1: Test helper and failing spec**

```ruby
# spec/support/dashboard_helpers.rb
# frozen_string_literal: true

module DashboardHelpers
  # Signs in by creating the session row and the signed cookie directly.
  # The sign-in endpoints themselves are covered in sessions_spec.
  def sign_in_as(user, livemode: true, stepped_up: false)
    session = Session.create!(principal: user, ip: "127.0.0.1", user_agent: "rspec", livemode:,
                              stepped_up_at: stepped_up ? Time.current : nil)
    jar = ActionDispatch::Request.new(Rails.application.env_config.merge("HTTP_HOST" => "www.example.com")).cookie_jar
    jar.signed[:_payhub_dashboard] = session.id
    cookies[:_payhub_dashboard] = jar[:_payhub_dashboard]
    session
  end

  def ui_headers(idempotency_key: SecureRandom.uuid)
    { "Content-Type" => "application/json", "Accept" => "application/json", "Idempotency-Key" => idempotency_key }
  end
end

RSpec.configure { |c| c.include DashboardHelpers, type: :request }
```

If the cookie does not round-trip (path scoping in the test jar), sign in through `POST /dashboard/api/session` + `/session/otp` instead, generating the code with `ROTP::TOTP.new(user.otp_secret).now`. Keep the helper's signature the same.

```ruby
# spec/requests/dashboard/api/me_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "GET /dashboard/api/me", type: :request do
  let(:user) { create(:merchant_user, role: "support") }

  it "401s without a session" do
    get "/dashboard/api/me"
    expect(response).to have_http_status(:unauthorized)
  end

  it "returns the user, the live merchant, the mode and the role's permissions" do
    sign_in_as(user)
    get "/dashboard/api/me"
    body = json_body
    expect(body.dig("user", "email")).to eq(user.email)
    expect(body["livemode"]).to be(true)
    expect(body["permissions"]).to match_array(Permissions.for(:merchant, "support").to_a)
  end

  it "401s once the session has been idle for 15 minutes" do
    sign_in_as(user)
    travel 16.minutes
    get "/dashboard/api/me"
    expect(response).to have_http_status(:unauthorized)
  end

  it "401s for a disabled user even with a live session" do
    sign_in_as(user)
    user.update!(disabled_at: Time.current)
    get "/dashboard/api/me"
    expect(response).to have_http_status(:unauthorized)
  end

  it "reflects a role change on the very next request" do
    sign_in_as(user)
    user.update!(role: "viewer")
    get "/dashboard/api/me"
    expect(json_body["permissions"]).not_to include("payments.refund")
  end
end
```

Run: `bundle exec rspec spec/requests/dashboard/api/me_spec.rb`
Expected: FAIL (routing error).

**Step 2: Base controller**

```ruby
# app/controllers/dashboard/api/base_controller.rb
# typed: true
# frozen_string_literal: true

module Dashboard
  module Api
    # Every /dashboard/api controller. Layer order (design §3): session (401),
    # tenant scoping via current_merchant (404), permission (403), record
    # rules in services (409/422), step-up (401 step_up_required).
    class BaseController < Web::BaseController
      include IdempotentAction

      COOKIE = :_payhub_dashboard
      IDLE_TIMEOUT = 15.minutes

      wrap_parameters false
      before_action :require_session!

      rescue_from ActiveRecord::RecordNotFound do
        Metrics.increment(:tenant_not_found, area: "merchant")
        render_api_error(ApiError.not_found("resource"))
      end
      rescue_from ActionController::ParameterMissing do |e|
        render_api_error(ApiError.invalid_request("Missing parameter: #{e.param}", param: e.param.to_s))
      end
      rescue_from PspAdapter::Unavailable, PspAdapter::TimedOut do |e|
        render_api_error(ApiError.new(type: ApiError::Type::ApiErrorType, http_status: 503, code: "psp_unavailable",
                                      message: e.message, retriable: true))
      end

      private

      def require_session!
        row = Session.find_by(id: cookies.signed[COOKIE], principal_type: "MerchantUser")
        user = row&.principal
        raise ApiError.unauthenticated unless row&.active?(idle: IDLE_TIMEOUT) && user.is_a?(MerchantUser) && user.active?

        @current_session = row
        @current_user = user
        row.touch_activity!
      end

      def current_session = T.must(@current_session)
      def current_user = T.must(@current_user)
      def live_merchant = T.must(current_user.merchant)

      # Tenant scoping (layer 2): every query starts here.
      def current_merchant = current_session.livemode ? live_merchant : live_merchant.test_twin!

      def authorization_area = :merchant
      def authorization_role = @current_user&.role
      def authorization_actor = @current_user
      def authorization_merchant_id = @current_user&.merchant_id
      def step_up_fresh? = @current_session&.stepped_up? || false

      # Security history rows always belong to the LIVE merchant.
      def audit!(action, target: nil, result: "success", metadata: {})
        AuditEvent.record!(
          action:, result:, actor: current_user, actor_label: current_user.email, merchant_id: live_merchant.id,
          target:, ip: request.remote_ip, user_agent: request.user_agent, request_id: request.request_id,
          metadata: metadata.merge("livemode" => current_session.livemode)
        )
      end

      def set_session_cookie(session_row)
        cookies.signed[COOKIE] = { value: session_row.id, httponly: true, same_site: :strict,
                                   secure: Rails.env.production?, path: "/dashboard" }
      end
    end
  end
end
```

Add `tenant_not_found: [:area]` to `Metrics::COUNTERS`.

```ruby
# app/controllers/dashboard/api/me_controller.rb
# typed: true
# frozen_string_literal: true

module Dashboard
  module Api
    class MeController < BaseController
      allow_unauthorized only: :show # any signed-in user; require_session! still runs

      def show = render(json: MePresenter.call(current_user, current_session))
    end
  end
end
```

```ruby
# app/presenters/me_presenter.rb
# typed: true
# frozen_string_literal: true

# The Vue app's view of "who am I". permissions[] drives navigation only;
# the server re-checks every request (design §3).
module MePresenter
  def self.call(user, session)
    merchant = T.must(user.merchant)
    {
      "user" => { "id" => user.id, "email" => user.email, "name" => user.name, "role" => user.role },
      "merchant" => { "id" => merchant.id, "name" => merchant.name },
      "livemode" => session.livemode,
      "stepped_up_until" => session.stepped_up_at && (session.stepped_up_at + Session::STEP_UP_WINDOW).utc.iso8601,
      "permissions" => Permissions.for(:merchant, user.role).to_a.sort
    }
  end
end
```

`allow_unauthorized` here means "no permission needed", not "no login": `require_session!` still runs first. Say so in a comment wherever it is used on a signed-in endpoint.

Routes, **above** the shell routes in `config/routes.rb`:

```ruby
  namespace :dashboard do
    namespace :api, defaults: { format: :json } do
      get "me", to: "me#show"
    end
  end
```

**Step 3: Run and commit**

Run: `bundle exec rspec spec/requests/dashboard spec/routing spec/requests/web`
Expected: PASS (the shell spec still serves `/dashboard/payments/abc`).

```bash
bin/check && git add app/controllers/dashboard app/presenters app/lib/metrics.rb config/routes.rb spec && \
  git commit -m "Add the dashboard API base: cookie session, idle timeout, tenant scoping by mode"
```

---

### Task 7: Sign in, 2FA, recovery, step-up, sign out

**Files:**
- Create: `app/controllers/concerns/two_factor_session_actions.rb`, `app/controllers/dashboard/api/sessions_controller.rb`
- Create: `app/mailers/security_mailer.rb`, `app/views/security_mailer/new_sign_in.text.erb`
- Modify: `config/routes.rb`, `config/initializers/rack_attack.rb`
- Test: `spec/requests/dashboard/api/sessions_spec.rb`, `spec/mailers/security_mailer_spec.rb`

The session logic lives in a concern parameterised by principal class and cookie, so Phase 2's operator login is a 10-line controller.

**Step 1: Failing spec**

```ruby
# spec/requests/dashboard/api/sessions_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Dashboard sign-in", type: :request do
  let!(:user) { create(:merchant_user, email: "sam@example.com") }
  let(:password) { "correct horse battery staple" }

  def code = ROTP::TOTP.new(user.reload.otp_secret).now

  it "needs password, then code, then gives a session" do
    post "/dashboard/api/session", params: { email: "sam@example.com", password: }.to_json, headers: ui_headers
    expect(json_body).to eq("otp_required" => true)

    get "/dashboard/api/me"
    expect(response).to have_http_status(:unauthorized) # password alone is not a session

    post "/dashboard/api/session/otp", params: { code: }.to_json, headers: ui_headers
    expect(response).to have_http_status(:ok)
    get "/dashboard/api/me"
    expect(response).to have_http_status(:ok)
  end

  it "rejects a code without a password step first" do
    post "/dashboard/api/session/otp", params: { code: }.to_json, headers: ui_headers
    expect(response).to have_http_status(:unauthorized)
  end

  it "answers the same for an unknown email and a wrong password" do
    post "/dashboard/api/session", params: { email: "nobody@example.com", password: }.to_json, headers: ui_headers
    unknown = [response.status, json_body.dig("error", "code")]
    post "/dashboard/api/session", params: { email: "sam@example.com", password: "wrong-password-123" }.to_json, headers: ui_headers
    expect([response.status, json_body.dig("error", "code")]).to eq(unknown)
  end

  it "locks with 423 after 10 failures, counting wrong codes too" do
    post "/dashboard/api/session", params: { email: "sam@example.com", password: }.to_json, headers: ui_headers
    10.times { post "/dashboard/api/session/otp", params: { code: "000000" }.to_json, headers: ui_headers }
    post "/dashboard/api/session", params: { email: "sam@example.com", password: }.to_json, headers: ui_headers
    expect(response).to have_http_status(423)
  end

  it "signs in with a recovery code, once" do
    codes = RecoveryCode.regenerate!(user)
    post "/dashboard/api/session", params: { email: "sam@example.com", password: }.to_json, headers: ui_headers
    post "/dashboard/api/session/recovery", params: { code: codes.first }.to_json, headers: ui_headers
    expect(response).to have_http_status(:ok)
  end

  it "steps up with a fresh code and records it" do
    sign_in_as(user)
    post "/dashboard/api/session/step_up", params: { code: }.to_json, headers: ui_headers
    expect(response).to have_http_status(:ok)
    expect(Session.last.stepped_up_at).to be_present
  end

  it "signs out and revokes the session row" do
    session = sign_in_as(user)
    delete "/dashboard/api/session", headers: ui_headers
    expect(session.reload.revoked_at).to be_present
  end

  it "audits sign-in and emails on a new device" do
    Session.create!(principal: user, ip: "10.9.9.9", user_agent: "old browser") # has signed in before
    post "/dashboard/api/session", params: { email: "sam@example.com", password: }.to_json, headers: ui_headers
    expect do
      post "/dashboard/api/session/otp", params: { code: }.to_json, headers: ui_headers
    end.to change(AuditEvent.where(action: "session.created"), :count).by(1)
       .and have_enqueued_mail(SecurityMailer, :new_sign_in)
  end

  it "refuses a write without the CSRF token" do
    ActionController::Base.allow_forgery_protection = true
    sign_in_as(user)
    delete "/dashboard/api/session", headers: ui_headers
    expect(response).to have_http_status(:unprocessable_content).or have_http_status(:forbidden)
  ensure
    ActionController::Base.allow_forgery_protection = false
  end
end
```

If `ActionController::InvalidAuthenticityToken` propagates instead of rendering, add `rescue_from ActionController::InvalidAuthenticityToken` in `Web::BaseController`, rendering `ApiError.new(type: ApiError::Type::InvalidRequest, http_status: 403, code: "invalid_csrf_token", message: "Reload the page and try again")`, and assert 403.

Run: `bundle exec rspec spec/requests/dashboard/api/sessions_spec.rb`
Expected: FAIL (routing error).

**Step 2: The concern**

```ruby
# app/controllers/concerns/two_factor_session_actions.rb
# typed: false
# frozen_string_literal: true

# Password → TOTP (or recovery code) → session, plus step-up and sign-out.
# The including controller defines principal_scope and session_cookie_path,
# and gets set_session_cookie from its area base controller.
# typed: false: uses the controller API (cookies, params, render).
module TwoFactorSessionActions
  extend ActiveSupport::Concern

  PENDING_TTL = 5.minutes

  def create
    result = SignIn.password(principal_scope, email: params.require(:email), password: params.require(:password))
    case result.status
    when :locked then raise ApiError.locked(result.principal&.locked_until || SignIn::LOCKED_FALLBACK.from_now)
    when :invalid then raise ApiError.unauthenticated(code: "invalid_credentials", message: "Email or password is wrong")
    end

    cookies.encrypted[pending_cookie] = { value: { "id" => result.principal.id, "exp" => PENDING_TTL.from_now.to_i },
                                          httponly: true, same_site: :strict, secure: Rails.env.production?,
                                          path: session_cookie_path }
    render json: { otp_required: true }
  end

  def otp = second_factor { |principal| principal.verify_otp!(params.require(:code)) }
  def recovery = second_factor { |principal| RecoveryCode.consume!(principal, params.require(:code)) }

  def step_up
    unless current_user.verify_otp!(params.require(:code))
      current_user.register_failure!
      raise ApiError.unauthenticated(code: "invalid_code", message: "That code is not valid")
    end
    current_session.step_up!
    audit!("session.stepped_up")
    render json: { stepped_up_until: (current_session.stepped_up_at + Session::STEP_UP_WINDOW).utc.iso8601 }
  end

  def destroy
    current_session.revoke!
    audit!("session.revoked")
    cookies.delete(session_cookie_name, path: session_cookie_path)
    head :no_content
  end

  private

  def pending_cookie = :"#{session_cookie_name}_2fa"

  def pending_principal
    data = cookies.encrypted[pending_cookie]
    return nil unless data.is_a?(Hash) && data["exp"].to_i > Time.current.to_i

    principal_scope.active.find_by(id: data["id"])
  end

  def second_factor
    principal = pending_principal
    raise ApiError.unauthenticated(code: "password_step_required", message: "Enter your password first") unless principal
    raise ApiError.locked(principal.locked_until) if principal.locked?

    unless yield(principal)
      principal.register_failure!
      raise ApiError.unauthenticated(code: "invalid_code", message: "That code is not valid")
    end

    principal.reset_failures!
    session_row = Session.create!(principal:, ip: request.remote_ip, user_agent: request.user_agent)
    notify_if_new_device(principal, session_row)
    cookies.delete(pending_cookie, path: session_cookie_path)
    set_session_cookie(session_row)
    @current_session = session_row
    @current_user = principal
    audit!("session.created")
    render json: session_payload(principal, session_row)
  end

  def notify_if_new_device(principal, session_row)
    earlier = principal.sessions.where.not(id: session_row.id)
    return unless earlier.exists?
    return if earlier.exists?(ip: session_row.ip, user_agent: session_row.user_agent)

    SecurityMailer.new_sign_in(principal, ip: session_row.ip, user_agent: session_row.user_agent).deliver_later
  end
end
```

Add `LOCKED_FALLBACK = TwoFactorPrincipal::LOCK_FOR` to `SignIn`.

```ruby
# app/controllers/dashboard/api/sessions_controller.rb
# typed: true
# frozen_string_literal: true

module Dashboard
  module Api
    class SessionsController < BaseController
      include TwoFactorSessionActions

      skip_before_action :require_session!, only: %i[create otp recovery]
      # Signing in needs no permission; step_up and destroy still need a session.
      allow_unauthorized only: %i[create otp recovery step_up destroy]

      private

      def principal_scope = MerchantUser
      def session_cookie_name = COOKIE
      def session_cookie_path = "/dashboard"
      def session_payload(user, session_row) = MePresenter.call(user, session_row)
    end
  end
end
```

Routes (inside `namespace :api`):

```ruby
      resource :session, only: %i[create destroy] do
        post :otp
        post :recovery
        post :step_up
      end
```

**Step 3: Mailer**

```ruby
# app/mailers/security_mailer.rb
# frozen_string_literal: true

class SecurityMailer < ApplicationMailer
  def new_sign_in(principal, ip:, user_agent:)
    @ip = ip
    @user_agent = user_agent
    @at = Time.current
    mail(to: principal.email, subject: "New sign-in to PayHub")
  end

  def ownership_transferred(user, from:, to:)
    @from = from
    @to = to
    mail(to: user.email, subject: "PayHub account ownership was transferred")
  end
end
```

`app/views/security_mailer/new_sign_in.text.erb`:

```erb
A new sign-in to your PayHub account at <%= @at.utc.iso8601 %> from <%= @ip %> (<%= @user_agent %>).
If this was not you, reset your password and tell your account owner.
```

`app/views/security_mailer/ownership_transferred.text.erb`:

```erb
Ownership of the PayHub account moved from <%= @from %> to <%= @to %>.
```

Mailer spec: assert `SecurityMailer.new_sign_in(user, ip: "1.2.3.4", user_agent: "x").deliver_now` adds one delivery to `user.email` whose body includes `1.2.3.4`.

**Step 4: Throttle sign-in by IP**

In `config/initializers/rack_attack.rb`:

```ruby
  # Password and code guessing. The per-account lockout (10 failures) is the
  # real control; this one stops one IP spraying many accounts.
  throttle("ui/sign-in-ip", limit: 20, period: 1.minute) do |req|
    req.ip if req.post? && req.path.match?(%r{\A/(dashboard|ops)/api/session(/otp|/recovery)?\z})
  end
```

**Step 5: Run and commit**

Run: `bundle exec rspec spec/requests/dashboard spec/mailers spec/services/sign_in_spec.rb`
Expected: PASS.

```bash
bin/check && git add app config spec && \
  git commit -m "Add merchant sign-in with TOTP, recovery codes, step-up, lockout and new-device email"
```

---

### Task 8: Invitations and 2FA enrolment

**Files:**
- Create: `app/controllers/dashboard/api/invitations_controller.rb`, `app/controllers/dashboard/api/otp_controller.rb`
- Create: `app/mailers/invitation_mailer.rb`, `app/views/invitation_mailer/invite.text.erb`
- Modify: `config/routes.rb`
- Test: `spec/requests/dashboard/api/invitations_spec.rb`, `spec/mailers/invitation_mailer_spec.rb`

**Step 1: Failing spec**

```ruby
# spec/requests/dashboard/api/invitations_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Invitations and enrolment", type: :request do
  let(:admin) { create(:merchant_user, role: "admin") }

  def invite(email: "new@example.com", role: "support")
    post "/dashboard/api/invitations", params: { email:, role: }.to_json, headers: ui_headers
  end

  it "needs step-up to invite" do
    sign_in_as(admin)
    invite
    expect(json_body.dig("error", "code")).to eq("step_up_required")
  end

  it "invites, emails a link, and audits" do
    sign_in_as(admin, stepped_up: true)
    expect { invite }.to have_enqueued_mail(InvitationMailer, :invite)
    expect(response).to have_http_status(:created)
    expect(AuditEvent.last).to have_attributes(action: "team.invited")
  end

  it "refuses to invite an owner, and a viewer cannot invite at all" do
    sign_in_as(admin, stepped_up: true)
    invite(role: "owner")
    expect(response).to have_http_status(:unprocessable_content)

    sign_in_as(create(:merchant_user, merchant: admin.merchant, role: "viewer"), stepped_up: true)
    invite(email: "other@example.com")
    expect(response).to have_http_status(:forbidden)
  end

  it "accepts, enrols 2FA, returns recovery codes once, and signs in" do
    user, token = MerchantUser.invite!(merchant: admin.merchant, email: "new@example.com", role: "support", invited_by: admin)

    get "/dashboard/api/invitations/#{token}"
    expect(json_body).to include("email" => "new@example.com", "merchant_name" => admin.merchant.name)

    post "/dashboard/api/invitations/#{token}/accept",
         params: { name: "New", password: "a long enough password" }.to_json, headers: ui_headers
    expect(response).to have_http_status(:ok)

    get "/dashboard/api/otp/setup"
    expect(json_body["qr_svg"]).to start_with("<svg")

    post "/dashboard/api/otp/confirm", params: { code: ROTP::TOTP.new(user.reload.otp_secret).now }.to_json,
                                       headers: ui_headers
    expect(json_body["recovery_codes"].size).to eq(10)
    expect(user.reload).to have_attributes(otp_enabled?: true, invitation_digest: nil)

    get "/dashboard/api/me"
    expect(response).to have_http_status(:ok)
  end

  it "refuses an expired invitation" do
    _user, token = MerchantUser.invite!(merchant: admin.merchant, email: "late@example.com", role: "viewer", invited_by: admin)
    travel 11.days
    get "/dashboard/api/invitations/#{token}"
    expect(response).to have_http_status(:not_found)
  end
end
```

Run: `bundle exec rspec spec/requests/dashboard/api/invitations_spec.rb`
Expected: FAIL.

**Step 2: Controllers**

```ruby
# app/controllers/dashboard/api/invitations_controller.rb
# typed: true
# frozen_string_literal: true

module Dashboard
  module Api
    class InvitationsController < BaseController
      ENROL_COOKIE = :_payhub_dashboard_enrol
      ENROL_TTL = 15.minutes

      skip_before_action :require_session!, only: %i[show accept]
      requires_permission "team.manage", only: :create
      allow_unauthorized only: %i[show accept] # the token is the credential

      def create
        role = params.require(:role).to_s
        unless MerchantUser::INVITABLE_ROLES.include?(role)
          raise ApiError.validation("role" => ["must be one of #{MerchantUser::INVITABLE_ROLES.join(', ')}"])
        end

        user, token = MerchantUser.invite!(merchant: live_merchant, email: params.require(:email), role:,
                                           invited_by: current_user)
        InvitationMailer.invite(user, token).deliver_later
        audit!("team.invited", target: user, metadata: { "email" => user.email, "role" => role })
        render json: MemberSerializer.call(user), status: :created
      rescue ActiveRecord::RecordNotUnique
        raise ApiError.validation("email" => ["already belongs to a PayHub user"])
      end

      def show
        user = invitation!
        render json: { "email" => user.email, "role" => user.role, "merchant_name" => T.must(user.merchant).name }
      end

      def accept
        user = invitation!
        user.update!(name: params.require(:name), password: params.require(:password))
        cookies.encrypted[ENROL_COOKIE] = { value: { "id" => user.id, "exp" => ENROL_TTL.from_now.to_i },
                                            httponly: true, same_site: :strict, secure: Rails.env.production?,
                                            path: "/dashboard" }
        render json: { "next" => "enrol_otp" }
      rescue ActiveRecord::RecordInvalid => e
        raise ApiError.validation(e.record.errors.to_hash.transform_keys(&:to_s))
      end

      private

      def invitation! = MerchantUser.find_by_invitation_token(params[:token].to_s) || raise(ActiveRecord::RecordNotFound)
    end
  end
end
```

```ruby
# app/controllers/dashboard/api/otp_controller.rb
# typed: true
# frozen_string_literal: true

module Dashboard
  module Api
    # Enrolment right after accepting an invitation. The short-lived encrypted
    # enrol cookie, set by InvitationsController#accept, is the credential.
    class OtpController < BaseController
      skip_before_action :require_session!
      allow_unauthorized only: %i[setup confirm]

      def setup
        user = enrolling_user!
        uri = Otp.provisioning_uri(T.must(user.otp_secret), user.email)
        render json: { "provisioning_uri" => uri, "qr_svg" => Otp.qr_svg(uri) }
      end

      def confirm
        user = enrolling_user!
        raise ApiError.unauthenticated(code: "invalid_code", message: "That code is not valid") unless user.verify_otp!(params.require(:code))

        user.update!(otp_enabled_at: Time.current, accepted_at: Time.current, invitation_digest: nil)
        codes = RecoveryCode.regenerate!(user)
        session_row = Session.create!(principal: user, ip: request.remote_ip, user_agent: request.user_agent)
        cookies.delete(InvitationsController::ENROL_COOKIE, path: "/dashboard")
        set_session_cookie(session_row)
        @current_session = session_row
        @current_user = user
        audit!("user.enrolled", target: user)
        render json: MePresenter.call(user, session_row).merge("recovery_codes" => codes)
      end

      private

      def enrolling_user!
        data = cookies.encrypted[InvitationsController::ENROL_COOKIE]
        raise ApiError.unauthenticated(code: "enrolment_expired", message: "Open your invitation link again") unless
          data.is_a?(Hash) && data["exp"].to_i > Time.current.to_i

        MerchantUser.active.where(otp_enabled_at: nil).find_by(id: data["id"]) || raise(ApiError.unauthenticated)
      end
    end
  end
end
```

`accepted_at` is set only at 2FA confirmation, so a half-enrolled user cannot sign in (SignIn requires `accepted_at`).

Routes:

```ruby
      resources :invitations, only: %i[create show], param: :token do
        post :accept, on: :member
      end
      get "otp/setup", to: "otp#setup"
      post "otp/confirm", to: "otp#confirm"
```

**Step 3: Mailer and serializer**

```ruby
# app/mailers/invitation_mailer.rb
# frozen_string_literal: true

class InvitationMailer < ApplicationMailer
  def invite(user, token)
    @merchant_name = user.merchant.name
    @role = user.role
    options = Rails.application.config.action_mailer.default_url_options || {}
    base = "#{options[:protocol] || 'http'}://#{options.fetch(:host, 'localhost')}#{":#{options[:port]}" if options[:port]}"
    @url = "#{base}/dashboard/invitations/#{token}"
    mail(to: user.email, subject: "You're invited to #{@merchant_name} on PayHub")
  end
end
```

`app/views/invitation_mailer/invite.text.erb`:

```erb
You have been invited to <%= @merchant_name %> on PayHub as <%= @role %>.
Accept within 10 days: <%= @url %>
You will set a password and connect an authenticator app.
```

```ruby
# app/serializers/member_serializer.rb
# typed: true
# frozen_string_literal: true

module MemberSerializer
  def self.call(user)
    {
      "id" => user.id, "email" => user.email, "name" => user.name, "role" => user.role,
      "status" => if user.disabled_at then "removed"
                  elsif user.pending_invitation? then "invited"
                  else "active"
                  end,
      "invitation_expires_at" => user.invitation_expires_at&.utc&.iso8601,
      "created_at" => user.created_at.utc.iso8601
    }
  end
end
```

**Step 4: Run and commit**

Run: `bundle exec rspec spec/requests/dashboard spec/mailers`
Expected: PASS.

```bash
bin/check && git add app config spec && git commit -m "Invite teammates by email and enrol 2FA on acceptance"
```

---

### Task 9: Profile and mode switch

**Files:**
- Modify: `app/controllers/dashboard/api/me_controller.rb`, `config/routes.rb`
- Create: `app/controllers/dashboard/api/modes_controller.rb`
- Test: `spec/requests/dashboard/api/me_spec.rb`, `spec/requests/dashboard/api/modes_spec.rb`

Add to `MeController`:

```ruby
      # Changing credentials is sensitive even though no permission names it.
      before_action :require_step_up!, only: %i[password recovery_codes]
      allow_unauthorized only: %i[show password recovery_codes]

      def password
        unless current_user.authenticate(params.require(:current_password).to_s)
          raise ApiError.validation("current_password" => ["is wrong"])
        end
        current_user.update!(password: params.require(:new_password))
        current_user.sessions.where.not(id: current_session.id).where(revoked_at: nil).update_all(revoked_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
        audit!("user.password_changed")
        head :no_content
      rescue ActiveRecord::RecordInvalid => e
        raise ApiError.validation(e.record.errors.to_hash.transform_keys(&:to_s))
      end

      def recovery_codes
        codes = RecoveryCode.regenerate!(current_user)
        audit!("user.recovery_codes_regenerated")
        render json: { "recovery_codes" => codes }
      end

      private

      def require_step_up! = (raise ApiError.step_up_required unless current_session.stepped_up?)
```

```ruby
# app/controllers/dashboard/api/modes_controller.rb
# typed: true
# frozen_string_literal: true

module Dashboard
  module Api
    # M-18: switches which data space this session reads, live or the test twin.
    class ModesController < BaseController
      allow_unauthorized only: :update # every role may look at test data

      def update
        livemode = ActiveModel::Type::Boolean.new.cast(params.require(:livemode))
        current_session.update!(livemode:)
        render json: MePresenter.call(current_user, current_session)
      end
    end
  end
end
```

Routes:

```ruby
      resource :me, only: [], controller: "me" do
        patch :password
        post :recovery_codes
      end
      put "mode", to: "modes#update"
```

Specs:
- A password change needs step-up, then revokes the other sessions.
- A wrong current password gives 422.
- `PUT mode {livemode: false}`, then `GET me` has `livemode: false`.
- After switching, `GET /dashboard/api/payments` returns only the twin's payments (write this example in Task 10's spec, once payments exist).

```bash
bin/check && git add app config spec && git commit -m "Add password change, recovery code regeneration and the test/live mode switch"
```

---

### Task 10: Payments: home, list, export, detail with timeline and `can` flags, capture, cancel, refund

**Files:**
- Create: `app/controllers/dashboard/api/home_controller.rb`, `app/controllers/dashboard/api/payments_controller.rb`, `app/controllers/dashboard/api/refunds_controller.rb`
- Create: `app/services/payment_timeline.rb`, `app/services/payment_actions.rb`, `app/lib/payment_filters.rb`
- Modify: `app/controllers/v1/payments_controller.rb` (use `PaymentFilters`), `config/routes.rb`
- Test: `spec/services/payment_timeline_spec.rb`, `spec/services/payment_actions_spec.rb`, `spec/requests/dashboard/api/payments_spec.rb`

**Step 1: Failing service specs**

```ruby
# spec/services/payment_actions_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe PaymentActions do
  let(:all) { ->(_permission) { true } }
  let(:none) { ->(_permission) { false } }

  it "offers capture and cancel only on an authorized payment" do
    payment = create(:payment, state: "authorized")
    expect(described_class.call(payment, granted: all)).to include("capture" => true, "cancel" => true, "refund" => false)
  end

  it "offers nothing the role lacks, whatever the state" do
    payment = create(:payment, state: "authorized")
    expect(described_class.call(payment, granted: none).values_at("capture", "cancel", "refund")).to all(be(false))
  end

  it "offers refund on a captured payment with money left, and reports how much" do
    payment = create(:payment, state: "captured")
    Ledger.record_capture!(payment, 2500)
    expect(described_class.call(payment, granted: all)).to include("refund" => true, "refundable_minor" => 2500)
  end

  it "offers no action on an unknown payment, even to a role that holds every permission" do
    expect(described_class.call(create(:payment, state: "unknown"), granted: all).values_at("capture", "cancel", "refund"))
      .to all(be(false))
  end
end
```

Check `spec/factories/payments.rb`: the factory sets no `state`; if `state:` in `create` conflicts with the `pending` initial transition callback, create the payment and then `update_columns(state: …)` in a small `trait :in_state` helper. Use that trait in these specs.

```ruby
# spec/services/payment_timeline_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe PaymentTimeline do
  it "merges transitions, ledger transfers, refunds and events into one list ordered by time" do
    payment = create(:payment)
    payment.transition!(:authorized, sort_key: 1.minute.from_now, source: "worker")
    Ledger.record_capture!(payment, 2500)
    OutboundEvent.emit!(payment, "payment.captured")

    kinds = described_class.call(payment).map { |e| e["kind"] }
    expect(kinds).to include("transition", "ledger_transfer", "event")
    times = described_class.call(payment).map { |e| e["at"] }
    expect(times).to eq(times.sort)
  end

  it "shows each ledger transfer once, with its legs" do
    payment = create(:payment)
    Ledger.record_capture!(payment, 2500)
    transfer = described_class.call(payment).find { |e| e["kind"] == "ledger_transfer" }
    expect(transfer["legs"].map { |l| l["account"] }).to contain_exactly("psp_receivable", "merchant_payable")
  end
end
```

Run both. Expected: FAIL.

**Step 2: Services**

```ruby
# app/services/payment_actions.rb
# typed: true
# frozen_string_literal: true

# The `can` flags on a payment (design §3, "What the Vue app receives"):
# permission AND state machine AND money left. Only the server knows all three,
# so the UI never shows a button that would answer 409.
module PaymentActions
  def self.call(payment, granted:)
    authorized = payment.state == "authorized"
    captured = Ledger.captured_minor(payment)
    capturable = authorized ? payment.amount_minor - captured : 0
    refundable = %w[captured part_refunded].include?(payment.state) ? captured - Ledger.refunded_minor(payment) - Ledger.reserved_minor(payment) : 0

    {
      "capture" => granted.call("payments.capture") && capturable.positive? && !payment.captures.pending.exists?,
      "cancel" => granted.call("payments.cancel") && authorized,
      "refund" => granted.call("payments.refund") && refundable.positive?,
      "capturable_minor" => capturable,
      "refundable_minor" => refundable
    }
  end
end
```

```ruby
# app/services/payment_timeline.rb
# typed: true
# frozen_string_literal: true

# M-04: one list of everything that happened to a payment, oldest first.
module PaymentTimeline
  def self.call(payment)
    entries = []
    payment.transitions.each do |t|
      entries << { "kind" => "transition", "at" => t.created_at, "from" => t.from_state, "to" => t.to_state,
                   "source" => t.source, "applied" => t.applied?, "metadata" => t.metadata }
    end
    payment.captures.order(:created_at).each do |c|
      entries << { "kind" => "capture", "at" => c.created_at, "amount_minor" => c.amount_minor, "state" => c.state,
                   "failure_code" => c.failure_code }
    end
    payment.refunds.order(:created_at).each do |r|
      entries << { "kind" => "refund", "at" => r.created_at, "id" => r.id, "amount_minor" => r.amount_minor,
                   "state" => r.state, "reason" => r.reason }
    end
    payment.ledger_entries.includes(:account).group_by(&:transfer_id).each do |transfer_id, legs|
      entries << { "kind" => "ledger_transfer", "at" => legs.map(&:created_at).min, "transfer_id" => transfer_id,
                   "legs" => legs.map { |l| { "account" => l.account.kind, "direction" => l.direction, "amount_minor" => l.amount_minor } } }
    end
    OutboundEvent.where(payment_id: payment.id).includes(:delivery_attempts).order(:created_at).each do |e|
      entries << { "kind" => "event", "at" => e.created_at, "id" => e.id, "type" => e.event_type, "state" => e.state,
                   "attempts" => e.attempts }
    end
    entries.sort_by { |e| e["at"] }.each { |e| e["at"] = e["at"].utc.iso8601(3) }
  end
end
```

Check `LedgerEntry belongs_to :account` (the column is `account_id`). If the association has another name, use it.

```ruby
# app/lib/payment_filters.rb
# typed: true
# frozen_string_literal: true

# The list filters, shared by GET /v1/payments and the dashboard list/export.
module PaymentFilters
  def self.apply(scope, params)
    scope = scope.where(state: params[:state]) if params[:state].present?
    scope = scope.where(currency: params[:currency]) if params[:currency].present?
    scope = scope.where(created_at: Time.iso8601(params[:created_after])..) if params[:created_after].present?
    scope = scope.where(created_at: ..Time.iso8601(params[:created_before])) if params[:created_before].present?
    scope
  end
end
```

Use it in `V1::PaymentsController#index` (replace the four `scope = …` lines). `rescue ArgumentError` stays in the controller.

**Step 3: Failing request spec**

```ruby
# spec/requests/dashboard/api/payments_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Dashboard payments", type: :request do
  let(:merchant) { create(:merchant) }
  let(:support) { create(:merchant_user, merchant:, role: "support") }
  let(:viewer) { create(:merchant_user, merchant:, role: "viewer") }

  it "lists only the current merchant's payments, in the session's mode" do
    mine = create(:payment, merchant:)
    create(:payment) # another merchant's
    twin_payment = create(:payment, merchant: merchant.test_twin!)

    sign_in_as(viewer)
    get "/dashboard/api/payments"
    expect(json_body["data"].pluck("id")).to eq([mine.id])

    put "/dashboard/api/mode", params: { livemode: false }.to_json, headers: ui_headers
    get "/dashboard/api/payments"
    expect(json_body["data"].pluck("id")).to eq([twin_payment.id])
  end

  it "404s another merchant's payment rather than 403, so ids are not confirmed" do
    sign_in_as(viewer)
    get "/dashboard/api/payments/#{create(:payment).id}"
    expect(response).to have_http_status(:not_found)
  end

  it "returns the timeline and can flags for the viewer's role" do
    payment = create(:payment, merchant:)
    sign_in_as(viewer)
    get "/dashboard/api/payments/#{payment.id}"
    expect(json_body).to include("timeline", "can")
    expect(json_body.dig("can", "refund")).to be(false)
  end

  it "exports the filtered list as CSV without tokens" do
    create(:payment, merchant:, payment_method_token: "tok_secret")
    sign_in_as(viewer)
    get "/dashboard/api/payments/export.csv"
    expect(response.media_type).to eq("text/csv")
    expect(response.body.lines.first).to start_with("id,created_at,state")
    expect(response.body).not_to include("tok_secret")
  end

  describe "refund" do
    let(:payment) { create(:payment, merchant:).tap { |p| p.update_columns(state: "captured") } } # rubocop:disable Rails/SkipsModelValidations

    before { Ledger.record_capture!(payment, 2500) }

    it "requires a reason, step-up and an idempotency key, then reuses CreateRefund" do
      sign_in_as(support, stepped_up: true)
      post "/dashboard/api/payments/#{payment.id}/refunds", params: { amount_minor: 1000 }.to_json, headers: ui_headers
      expect(response).to have_http_status(:unprocessable_content)

      key = SecureRandom.uuid
      2.times do
        post "/dashboard/api/payments/#{payment.id}/refunds", params: { amount_minor: 1000, reason: "requested_by_customer" }.to_json,
                                                               headers: ui_headers(idempotency_key: key)
      end
      expect(payment.refunds.count).to eq(1)
      expect(response.headers["Idempotent-Replayed"]).to eq("true")
    end

    it "denies a viewer before the idempotency guard claims anything" do
      sign_in_as(viewer, stepped_up: true)
      expect do
        post "/dashboard/api/payments/#{payment.id}/refunds", params: { amount_minor: 1000, reason: "x" }.to_json,
                                                               headers: ui_headers
      end.not_to change(IdempotencyKey, :count)
      expect(response).to have_http_status(:forbidden)
    end
  end
end
```

Run: `bundle exec rspec spec/requests/dashboard/api/payments_spec.rb`
Expected: FAIL.

**Step 4: Controllers**

```ruby
# app/controllers/dashboard/api/payments_controller.rb
# typed: true
# frozen_string_literal: true

module Dashboard
  module Api
    class PaymentsController < BaseController
      EXPORT_LIMIT = 10_000
      CSV_COLUMNS = %w[id created_at state amount_minor currency captured_minor psp_name psp_reference].freeze

      requires_permission "payments.read", only: %i[index show]
      requires_permission "payments.export", only: :export
      requires_permission "payments.capture", only: :capture
      requires_permission "payments.cancel", only: :cancel
      idempotent only: %i[capture cancel] # after requires_permission: denials never claim a key

      def index
        page = Cursor.paginate(filtered, after: params[:cursor].presence, limit: params[:limit]&.to_i)
        render json: { "object" => "list", "data" => page.records.map { |p| PaymentSerializer.call(p) },
                       "has_more" => page.has_more, "next_cursor" => page.next_cursor }
      rescue Cursor::Invalid => e
        raise ApiError.invalid_request(e.message, param: "cursor", code: "invalid_cursor")
      end

      def export
        rows = filtered.order(created_at: :desc, id: :desc).limit(EXPORT_LIMIT + 1).to_a
        response.set_header("X-Export-Truncated", "true") if rows.size > EXPORT_LIMIT
        csv = CSV.generate do |out|
          out << CSV_COLUMNS
          rows.first(EXPORT_LIMIT).each do |p|
            out << [p.id, p.created_at.utc.iso8601, p.state, p.amount_minor, p.currency, p.captured_minor, p.psp_name, p.psp_reference]
          end
        end
        send_data csv, type: "text/csv", filename: "payments-#{Time.current.utc.to_date}.csv"
      end

      def show
        payment = current_merchant.payments.find(params[:id])
        render json: detail(payment)
      end

      def capture
        payment = current_merchant.payments.find(params[:id])
        CapturePayment.call(payment, amount_minor: optional_amount)
        audit!("payment.capture_requested", target: payment)
        render json: detail(payment.reload), status: :accepted
      end

      def cancel
        payment = current_merchant.payments.find(params[:id])
        CancelPayment.call(payment, source: "api", reason: params[:reason].presence&.to_s)
        audit!("payment.canceled", target: payment)
        render json: detail(payment.reload)
      end

      private

      def filtered
        PaymentFilters.apply(current_merchant.payments, params)
      rescue ArgumentError => e
        raise ApiError.invalid_request("created_after/created_before must be ISO-8601: #{e.message}", param: "created_after")
      end

      def detail(payment)
        PaymentSerializer.call(payment).merge(
          "timeline" => PaymentTimeline.call(payment),
          "can" => PaymentActions.call(payment, granted: ->(p) { permission_granted?(p) })
        )
      end

      def optional_amount
        raw = params[:amount_minor]
        return nil if raw.nil?
        return raw if raw.is_a?(Integer) && raw.positive?

        raise ApiError.validation("amount_minor" => ["must be a positive integer when present"])
      end
    end
  end
end
```

```ruby
# app/controllers/dashboard/api/refunds_controller.rb
# typed: true
# frozen_string_literal: true

module Dashboard
  module Api
    # M-07: same service as /v1, but the UI requires a reason (use cases).
    class RefundsController < BaseController
      REASONS = %w[requested_by_customer duplicate fraudulent other].freeze

      requires_permission "payments.refund", only: :create
      idempotent only: :create

      def create
        payment = current_merchant.payments.find(params[:payment_id])
        reason = params[:reason].to_s
        raise ApiError.validation("reason" => ["must be one of #{REASONS.join(', ')}"]) unless REASONS.include?(reason)

        amount = params[:amount_minor]
        raise ApiError.validation("amount_minor" => ["must be a positive integer"]) unless amount.nil? || (amount.is_a?(Integer) && amount.positive?)

        refund = CreateRefund.call(payment, amount_minor: amount, reason:)
        audit!("payment.refund_requested", target: payment, metadata: { "refund_id" => refund.id, "amount_minor" => refund.amount_minor })
        render json: RefundSerializer.call(refund), status: :accepted
      end
    end
  end
end
```

```ruby
# app/controllers/dashboard/api/home_controller.rb
# typed: true
# frozen_string_literal: true

module Dashboard
  module Api
    # M-01: attention first, then volume and balance.
    class HomeController < BaseController
      requires_permission "payments.read", only: :show

      def show
        payments = current_merchant.payments
        render json: {
          "needs_attention" => payments.where(state: %w[requires_action unknown]).group(:state).count,
          "volume_7d" => payments.where(created_at: 7.days.ago..).where.not(state: %w[failed canceled])
                                 .group(:currency).sum(:amount_minor),
          "balance" => permission_granted?("balance.read") ? Ledger.balances(current_merchant) : nil
        }
      end
    end
  end
end
```

Routes (inside `namespace :api`):

```ruby
      get "home", to: "home#show"
      resources :payments, only: %i[index show] do
        get :export, on: :collection
        member do
          post :capture
          post :cancel
        end
        resources :refunds, only: :create
      end
```

**Step 5: Run and commit**

Run: `bundle exec rspec spec/requests/dashboard spec/services spec/requests/v1`
Expected: PASS. Also run `bundle exec rspec spec/requests/v1/payments_index_spec.rb`, which guards the <100ms keyset contract of the shared filters.

```bash
bin/check && git add app config spec && \
  git commit -m "Add dashboard payments: home, list, CSV export, timeline detail, capture, cancel and refund"
```

---

### Task 11: Balance and settlements

**Files:**
- Create: `app/controllers/dashboard/api/balances_controller.rb`, `app/controllers/dashboard/api/settlements_controller.rb`
- Test: `spec/requests/dashboard/api/balances_spec.rb`

```ruby
# app/controllers/dashboard/api/balances_controller.rb
# typed: true
# frozen_string_literal: true

module Dashboard
  module Api
    # M-08: available (merchant_payable) and reserved for refunds, per currency.
    class BalancesController < BaseController
      requires_permission "balance.read", only: :show

      def show
        available = Ledger.balances(current_merchant)
        reserved = Ledger.reserved_balances(current_merchant)
        currencies = (available.keys | reserved.keys).sort
        render json: {
          "data" => currencies.map do |c|
            { "currency" => c, "available_minor" => available.fetch(c, 0), "reserved_minor" => reserved.fetch(c, 0) }
          end
        }
      end
    end
  end
end
```

```ruby
# app/controllers/dashboard/api/settlements_controller.rb
# typed: true
# frozen_string_literal: true

module Dashboard
  module Api
    # M-09: what the PSP paid out and kept in fees, per day and currency.
    class SettlementsController < BaseController
      requires_permission "settlements.read", only: :index

      def index
        rows = SettlementLine.joins("JOIN payments ON payments.id = settlement_lines.payment_id")
                             .where(payments: { merchant_id: current_merchant.id })
                             .group(:settled_on, "settlement_lines.currency")
                             .order(settled_on: :desc).limit(90)
                             .pluck(:settled_on, "settlement_lines.currency", Arel.sql("SUM(gross_minor)"),
                                    Arel.sql("SUM(fee_minor)"), Arel.sql("SUM(net_minor)"))
        render json: {
          "data" => rows.map do |day, currency, gross, fee, net|
            { "settled_on" => day.iso8601, "currency" => currency, "gross_minor" => gross, "fee_minor" => fee, "net_minor" => net }
          end
        }
      end
    end
  end
end
```

Routes: `get "balance", to: "balances#show"` and `get "settlements", to: "settlements#index"`.

Spec:
- A viewer sees balance and settlements.
- A developer gets 403 on both.
- A settlement line for another merchant's payment is not summed.

To build a settlement line, `create` it directly with the columns listed in `db/structure.sql` (`psp_name`, `external_id`, `settled_on`, `kind: "capture"`, `psp_reference`, `payment:`, amounts, `booked_at`, `status: "matched"`).

```bash
bin/check && git add app config spec && git commit -m "Add balance per currency and daily settlements to the dashboard"
```

---

### Task 12: API keys

**Files:**
- Create: `app/controllers/dashboard/api/api_keys_controller.rb`, `app/serializers/api_key_serializer.rb`
- Modify: `app/models/api_key.rb` (`roll!`, `revoke!`, `status`)
- Test: `spec/models/api_key_spec.rb` (add), `spec/requests/dashboard/api/api_keys_spec.rb`

**Step 1: Model tests and methods**

Add to `spec/models/api_key_spec.rb`:

```ruby
  describe "#roll!" do
    it "issues a replacement with the same name and keeps the old key working for the overlap" do
      key, old_raw = described_class.issue!(merchant:, livemode: true, name: "Server")
      replacement, new_raw = key.roll!(overlap: 24.hours, by: nil)
      expect(replacement.name).to eq("Server")
      expect(described_class.authenticate(old_raw)).to eq(key)
      expect(described_class.authenticate(new_raw)).to eq(replacement)
      travel 25.hours
      expect(described_class.authenticate(old_raw)).to be_nil
    end

    it "with no overlap revokes the old key at once" do
      key, old_raw = described_class.issue!(merchant:, livemode: true, name: "Server")
      key.roll!(overlap: 0, by: nil)
      expect(described_class.authenticate(old_raw)).to be_nil
    end
  end
```

```ruby
  # In app/models/api_key.rb
  ROLL_OVERLAPS = { "now" => 0, "24h" => 24.hours, "7d" => 7.days }.freeze

  # Returns [replacement, raw]. The old key keeps working for `overlap` so a
  # deploy can pick up the new one (Stripe 7d, Adyen 24h).
  def roll!(overlap:, by:)
    transaction do
      overlap.to_i.zero? ? update!(revoked_at: Time.current) : update!(expires_at: overlap.from_now)
      ApiKey.issue!(merchant: T.must(merchant), livemode:, name:, note:, created_by_id: by&.id)
    end
  end

  def revoke! = update!(revoked_at: Time.current)

  def status
    return "revoked" if revoked_at
    return "expired" if expires_at&.past?

    expires_at ? "expiring" : "active"
  end
```

**Step 2: Controller**

```ruby
# app/controllers/dashboard/api/api_keys_controller.rb
# typed: true
# frozen_string_literal: true

module Dashboard
  module Api
    # M-10..M-13. Keys belong to the live merchant and carry livemode; the
    # list shows the keys of the session's current mode.
    class ApiKeysController < BaseController
      requires_permission "api_keys.read", only: :index
      requires_permission "api_keys.manage", only: %i[create roll revoke]

      def index
        keys = live_merchant.api_keys.where(livemode: current_session.livemode).order(created_at: :desc)
        render json: { "data" => keys.map { |k| ApiKeySerializer.call(k) } }
      end

      def create
        key, raw = ApiKey.issue!(merchant: live_merchant, livemode: current_session.livemode,
                                 name: params.require(:name), note: params[:note].presence, created_by_id: current_user.id)
        audit!("api_key.created", target: key, metadata: { "name" => key.name })
        render json: ApiKeySerializer.call(key).merge("secret" => raw), status: :created # shown once
      end

      def roll
        key = keys_in_mode.find(params[:id])
        overlap = ApiKey::ROLL_OVERLAPS.fetch(params.require(:expires_in).to_s) do
          raise ApiError.validation("expires_in" => ["must be one of #{ApiKey::ROLL_OVERLAPS.keys.join(', ')}"])
        end
        replacement, raw = key.roll!(overlap:, by: current_user)
        audit!("api_key.rolled", target: key, metadata: { "replacement_id" => replacement.id, "expires_in" => params[:expires_in] })
        render json: ApiKeySerializer.call(replacement).merge("secret" => raw), status: :created
      end

      def revoke
        key = keys_in_mode.find(params[:id])
        key.revoke!
        audit!("api_key.revoked", target: key)
        render json: ApiKeySerializer.call(key)
      end

      private

      def keys_in_mode = live_merchant.api_keys.where(livemode: current_session.livemode)
    end
  end
end
```

```ruby
# app/serializers/api_key_serializer.rb
# typed: true
# frozen_string_literal: true

# Never the secret or its digest: prefix and last 4 identify a key.
module ApiKeySerializer
  def self.call(key)
    {
      "id" => key.id, "name" => key.name, "note" => key.note, "livemode" => key.livemode,
      "redacted" => "#{key.prefix}…#{key.last4 || '????'}", "status" => key.status,
      "created_by" => key.created_by_id && MerchantUser.find_by(id: key.created_by_id)&.email,
      "created_at" => key.created_at.utc.iso8601, "last_used_at" => key.last_used_at&.utc&.iso8601,
      "expires_at" => key.expires_at&.utc&.iso8601, "revoked_at" => key.revoked_at&.utc&.iso8601
    }
  end
end
```

The `created_by` lookup is N+1 on the list. Add `belongs_to :created_by, class_name: "MerchantUser", optional: true` to `ApiKey`, use `key.created_by&.email`, and `includes(:created_by)` in `index`; prosopite fails the spec otherwise.

Routes:

```ruby
      resources :api_keys, only: %i[index create] do
        member do
          post :roll
          post :revoke
        end
      end
```

Request spec:
- A developer creates a key with step-up and sees `secret` once; `index` never includes `secret`.
- A support user gets 403.
- Without step-up the answer is 401 `step_up_required`.
- Roll `24h` keeps both keys authenticating on `/v1`.
- Revoke stops `/v1` at once.
- In test mode, `create` issues an `sk_test_` key.
- Every write adds an audit row.

```bash
bin/check && git add app config spec && git commit -m "Add API key create, roll with overlap and revoke to the dashboard"
```

---

### Task 13: Webhook endpoint, signing secret and event log

**Files:**
- Create: `app/controllers/dashboard/api/webhook_endpoints_controller.rb`, `app/controllers/dashboard/api/events_controller.rb`
- Test: `spec/requests/dashboard/api/webhooks_spec.rb`

```ruby
# app/controllers/dashboard/api/webhook_endpoints_controller.rb
# typed: true
# frozen_string_literal: true

module Dashboard
  module Api
    # M-14, M-15. Per mode: the test twin has its own endpoint and secret, so
    # test events can never reach the live endpoint (Phase 0 review, #1).
    class WebhookEndpointsController < BaseController
      requires_permission "webhooks.read", only: :show
      requires_permission "webhooks.manage", only: %i[update reveal_secret roll_secret]

      def show = render(json: endpoint_json)

      def update
        url = params.require(:url).to_s
        unless valid_url?(url)
          raise ApiError.validation("url" => ["must be an #{Rails.env.production? ? 'https' : 'http(s)'} URL"])
        end

        current_merchant.update!(webhook_url: url)
        audit!("webhook.endpoint_updated", metadata: { "url" => url })
        render json: endpoint_json
      end

      def reveal_secret
        audit!("webhook.secret_revealed")
        render json: { "secret" => current_merchant.webhook_secret }
      end

      def roll_secret
        fresh = current_merchant.rotate_webhook_secret!
        audit!("webhook.secret_rolled")
        render json: endpoint_json.merge("secret" => fresh)
      end

      private

      def endpoint_json
        m = current_merchant
        {
          "url" => m.webhook_url, "livemode" => m.livemode, "secret_last4" => m.webhook_secret.last(4),
          "previous_secret_expires_at" => m.previous_webhook_secret_expires_at&.future? ? m.previous_webhook_secret_expires_at&.utc&.iso8601 : nil
        }
      end

      def valid_url?(url)
        uri = URI.parse(url)
        allowed = Rails.env.production? ? %w[https] : %w[http https]
        allowed.include?(uri.scheme) && uri.host.present?
      rescue URI::InvalidURIError
        false
      end
    end
  end
end
```

```ruby
# app/controllers/dashboard/api/events_controller.rb
# typed: true
# frozen_string_literal: true

module Dashboard
  module Api
    # M-16, M-17: the delivery log. Same serializer as /v1/events.
    class EventsController < BaseController
      requires_permission "webhooks.read", only: %i[index show]
      requires_permission "events.redeliver", only: :redeliver

      def index
        scope = current_merchant.outbound_events.includes(:delivery_attempts)
        scope = scope.where(state: params[:state]) if params[:state].present?
        scope = scope.where(payment_id: params[:payment_id]) if params[:payment_id].present?
        page = Cursor.paginate(scope, after: params[:cursor].presence, limit: params[:limit]&.to_i)
        render json: { "object" => "list", "data" => page.records.map { |e| EventSerializer.call(e, include_attempts: false) },
                       "has_more" => page.has_more, "next_cursor" => page.next_cursor }
      rescue Cursor::Invalid => e
        raise ApiError.invalid_request(e.message, param: "cursor", code: "invalid_cursor")
      end

      def show = render(json: EventSerializer.call(current_merchant.outbound_events.find(params[:id])))

      def redeliver
        event = current_merchant.outbound_events.find(params[:id])
        raise ApiError.invalid_request("Only dead events can be redelivered (state: #{event.state})", code: "invalid_state", param: "id") unless event.dead?

        event.redeliver!
        DeliverOutboundEventsJob.perform_later
        audit!("event.redelivered", target: event)
        render json: EventSerializer.call(event.reload), status: :accepted
      end
    end
  end
end
```

Routes:

```ruby
      resource :webhook_endpoint, only: %i[show update] do
        post :reveal_secret
        post :roll_secret
      end
      resources :events, only: %i[index show] do
        post :redeliver, on: :member
      end
```

Spec:
- A developer sets the URL (422 on `ftp://x`).
- The test-mode endpoint is independent of live.
- `reveal_secret` needs step-up and writes an audit row.
- `roll_secret` keeps the previous secret signing for 24h (`webhook_signing_secrets.size == 2`).
- A support user gets 403 on `show`.
- `redeliver` of a delivered event gives 422.

```bash
bin/check && git add app config spec && git commit -m "Add webhook endpoint, secret reveal and roll, and the event delivery log"
```

---

### Task 14: Team: members, role changes, removal, ownership transfer

**Files:**
- Create: `app/controllers/dashboard/api/members_controller.rb`, `app/controllers/dashboard/api/ownership_transfers_controller.rb`, `app/services/change_member_role.rb`, `app/services/transfer_ownership.rb`
- Test: `spec/services/change_member_role_spec.rb`, `spec/services/transfer_ownership_spec.rb`, `spec/requests/dashboard/api/members_spec.rb`

Layer-4 rules (design §3) live in services, not controllers:

```ruby
# app/services/change_member_role.rb
# typed: true
# frozen_string_literal: true

# Who may give whom which role. The permission check (team.manage) already
# ran; these are the record rules roles cannot express.
module ChangeMemberRole
  class Refused < StandardError; end

  def self.call(actor:, member:, role:)
    raise Refused, "You cannot change your own role" if member.id == actor.id
    raise Refused, "The owner's role changes only through ownership transfer" if member.role == "owner" # authz-allow-role-check
    raise Refused, "Role must be one of #{MerchantUser::INVITABLE_ROLES.join(', ')}" unless MerchantUser::INVITABLE_ROLES.include?(role)

    member.update!(role:)
    member
  end

  def self.remove(actor:, member:)
    raise Refused, "You cannot remove yourself" if member.id == actor.id
    raise Refused, "The owner cannot be removed; transfer ownership first" if member.role == "owner" # authz-allow-role-check

    MerchantUser.transaction do
      member.update!(disabled_at: Time.current, invitation_digest: nil)
      member.revoke_sessions!
    end
    member
  end
end
```

```ruby
# app/services/transfer_ownership.rb
# typed: true
# frozen_string_literal: true

# M-21. Demote first, then promote: the one-owner partial unique index would
# refuse the other order.
module TransferOwnership
  class Refused < StandardError; end

  def self.call(owner:, to:)
    raise Refused, "Choose another active, enrolled team member" if to.id == owner.id || !to.active? || !to.otp_enabled?
    raise Refused, "Both people must belong to the same account" unless to.merchant_id == owner.merchant_id

    MerchantUser.transaction do
      owner.update!(role: "admin")
      to.update!(role: "owner")
    end
  end
end
```

The `# authz-allow-role-check` comments are required: `bin/check` greps for role-name comparisons. Assignment rules are the documented exception.

Controllers:
- `MembersController`: `index` needs `team.read` (live merchant's users, `MemberSerializer`). `update` needs `team.manage` and calls `ChangeMemberRole.call`. `destroy` needs `team.manage` and calls `ChangeMemberRole.remove`. `rescue ChangeMemberRole::Refused => e`, then `raise ApiError.new(type: ApiError::Type::InvalidRequest, http_status: 409, code: "refused", message: e.message)`. Audit `team.role_changed` (with `from`/`to`) and `team.removed`.
- `OwnershipTransfersController#create`: `requires_permission "ownership.transfer"`, `to = live_merchant.merchant_users.find(params.require(:member_id))`, call the service, audit `team.ownership_transferred`, and `SecurityMailer.ownership_transferred(user, from: owner.email, to: to.email).deliver_later` to both people.

Routes:

```ruby
      resources :members, only: %i[index update destroy]
      post "ownership_transfer", to: "ownership_transfers#create"
```

Specs:
- An admin cannot change their own role or the owner's (409).
- An admin cannot grant `owner` (422 from the role check, or 409; pick one and assert it).
- A removed member's sessions are revoked and they get 401 on the next request.
- An admin gets 403 on transfer.
- The owner transfers with step-up; afterwards exactly one owner exists and the old owner is admin.
- Both people are emailed.

```bash
bin/check && git add app config spec && git commit -m "Add team management and ownership transfer with record-level rules"
```

---

### Task 15: Security history

**Files:**
- Create: `app/controllers/dashboard/api/security_history_controller.rb`
- Test: `spec/requests/dashboard/api/security_history_spec.rb`

```ruby
# app/controllers/dashboard/api/security_history_controller.rb
# typed: true
# frozen_string_literal: true

module Dashboard
  module Api
    # M-22: the merchant's slice of the append-only audit log, 12 months.
    class SecurityHistoryController < BaseController
      EXPORT_LIMIT = 10_000

      requires_permission "security_history.read", only: %i[index export]

      def index
        page = Cursor.paginate(scope, after: params[:cursor].presence, limit: params[:limit]&.to_i)
        render json: { "object" => "list", "data" => page.records.map { |e| row(e) },
                       "has_more" => page.has_more, "next_cursor" => page.next_cursor }
      rescue Cursor::Invalid => e
        raise ApiError.invalid_request(e.message, param: "cursor", code: "invalid_cursor")
      end

      def export
        csv = CSV.generate do |out|
          out << %w[at actor action result target ip livemode]
          scope.order(created_at: :desc).limit(EXPORT_LIMIT).each do |e|
            out << [e.created_at.utc.iso8601, e.actor_label, e.action, e.result, e.target_type, e.ip, e.metadata["livemode"]]
          end
        end
        send_data csv, type: "text/csv", filename: "security-history-#{Time.current.utc.to_date}.csv"
      end

      private

      def scope = AuditEvent.where(merchant_id: live_merchant.id)

      def row(e)
        { "id" => e.id, "at" => e.created_at.utc.iso8601, "actor" => e.actor_label, "action" => e.action,
          "result" => e.result, "target_type" => e.target_type, "ip" => e.ip, "metadata" => e.metadata }
      end
    end
  end
end
```

Check `Cursor.paginate` orders by `(created_at DESC, id DESC)` and works on any model with those columns; `audit_events` has both. Routes: `get "security_history", to: "security_history#index"` and `get "security_history/export", to: "security_history#export"`. The client requests `export.csv`.

Spec:
- An admin sees their merchant's rows and never another merchant's.
- A developer gets 403.
- The CSV has a header and no metadata blobs.

```bash
bin/check && git add app config spec && git commit -m "Add the security history page and CSV export"
```

---

### Task 16: Audit retention, logging and CSP

**Files:**
- Create: `app/jobs/audit_retention_job.rb`, `config/initializers/content_security_policy.rb`
- Modify: `config/schedule.yml`, `config/initializers/lograge.rb`, `config/application.rb`, `app/controllers/web/base_controller.rb`
- Test: `spec/jobs/audit_retention_job_spec.rb`, `spec/requests/web/csp_spec.rb`

**Step 1: Retention job**

```ruby
# app/jobs/audit_retention_job.rb
# typed: true
# frozen_string_literal: true

# PCI DSS 10.5.1: keep 12 months. The append-only trigger lets exactly this
# through (rows older than the window) and nothing else.
class AuditRetentionJob < ApplicationJob
  queue_as :sweepers

  def perform
    cutoff = 12.months.ago - 1.day # a day of slack so we never race the trigger's own clock
    [AuditEvent, PspCall].each do |model|
      loop do
        ids = model.where(created_at: ...cutoff).limit(1_000).pluck(:id)
        break if ids.empty?

        model.where(id: ids).delete_all
      end
    end
  end
end
```

Spec: backdate rows with the `without_triggers` pattern from `spec/models/audit_event_spec.rb` (move that helper to `spec/support/database_helpers.rb` first). Check that old rows go and new rows stay.

`config/schedule.yml`:

```yaml
audit_retention:
  cron: "30 4 * * *"
  class: AuditRetentionJob
  queue: sweepers
  description: "Delete audit_events and psp_calls older than 12 months (PCI 10.5.1)"
```

**Step 2: Lograge for UI requests**

In `config/initializers/lograge.rb`, change `base_controller_class` to `["ActionController::API", "ActionController::Base"]`, and add:

```ruby
  # Polling endpoints mark themselves; one line per poll would drown the log.
  config.lograge.ignore_custom = ->(event) { event.payload[:skip_request_log] }
```

In `Web::BaseController`:

```ruby
    private

    # Picked up by lograge's custom_payload. Never params: they can hold secrets.
    def log_payload = { merchant_id: try(:authorization_merchant_id), skip_request_log: @skip_request_log }.compact
```

`PaymentsController#show` sets `@skip_request_log = true` when `request.headers["X-Poll"] == "1"`. The Vue client sends that header on refetches from `useLiveQuery`.

**Step 3: CSP for the UI**

`config/application.rb` (API-only apps lack the middleware):

```ruby
    config.middleware.use ActionDispatch::ContentSecurityPolicy::Middleware
```

```ruby
# config/initializers/content_security_policy.rb
# frozen_string_literal: true

# Applies to ActionController::Base (the UI) only; /v1 sends JSON.
Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.script_src :self
    policy.style_src :self, :unsafe_inline # Vue transitions and Vite's dev CSS injection
    policy.img_src :self, :data
    policy.connect_src :self
    policy.frame_ancestors :none
    policy.base_uri :self
    policy.form_action :self

    if Rails.env.development?
      vite = "http://#{ViteRuby.config.host_with_port}"
      policy.script_src(*policy.script_src, :unsafe_eval, vite)
      policy.connect_src(*policy.connect_src, vite, "ws://#{ViteRuby.config.host_with_port}")
    end
  end
end
```

Spec: `GET /dashboard` has a `Content-Security-Policy` header with `frame-ancestors 'none'`, and `GET /healthz` has none.

Verify by hand that `/dashboard` still loads in `bin/vite dev` (headless Chrome, as in Phase 0 Task 12). Under Docker Compose the assets are same-origin via the Rails proxy, so `:self` covers them.

```bash
bin/check && git add app config spec && git commit -m "Add audit retention, UI request logging and a content security policy"
```

---

### Task 17: Bootstrap the first owner

**Files:**
- Modify: `lib/tasks/merchants.rake`, `db/seeds.rb`
- Test: `spec/tasks/merchants_rake_spec.rb` (optional; a runner check is acceptable)

```ruby
  desc "Invite the first owner of a merchant (prints the invitation link; also emailed)"
  task :invite_owner, %i[merchant_id email] => :environment do |_t, args|
    merchant = Merchant.find(args.fetch(:merchant_id))
    abort "#{merchant.name} already has an owner" if merchant.merchant_users.active.exists?(role: "owner") # authz-allow-role-check

    token = SecureRandom.urlsafe_base64(32)
    user = merchant.merchant_users.create!(
      email: args.fetch(:email), role: "owner", otp_secret: Otp.generate_secret,
      invitation_digest: Digest::SHA256.hexdigest(token), invitation_expires_at: MerchantUser::INVITATION_TTL.from_now
    )
    InvitationMailer.invite(user, token).deliver_now
    puts "Invitation for #{user.email}: http://localhost:3000/dashboard/invitations/#{token}"
  end
```

`MerchantUser.invite!` refuses owners on purpose. This task is the only other way an owner is created, and it only works when there is none.

In `db/seeds.rb`, after the demo merchant block, invite `owner@demo.payhub.local` the same way when the demo merchant has no owner, and print the link.

Verify: `bin/rails "merchants:invite_owner[<id>,me@example.com]"`, open the printed link after Task 19, and complete enrolment.

```bash
bin/check && git add lib/tasks/merchants.rake db/seeds.rb && git commit -m "Add a task to invite a merchant's first owner, and seed one for the demo merchant"
```

---

### Task 18: Frontend foundations

**Files:**
- Create: `app/frontend/shared/http.ts`, `app/frontend/shared/http.test.ts`
- Create: `app/frontend/shared/useIdempotencyKey.ts`, `app/frontend/shared/useIdempotencyKey.test.ts`
- Create: `app/frontend/shared/useLiveQuery.ts`, `app/frontend/shared/pollInterval.ts`, `app/frontend/shared/pollInterval.test.ts`
- Create: `app/frontend/shared/money.ts`, `app/frontend/shared/money.test.ts`
- Modify: `package.json`

**Step 1: Dependencies**

```bash
npm install reka-ui
```

**Step 2: HTTP client (tests first)**

```ts
// app/frontend/shared/http.test.ts
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ApiFailure, createClient } from "./http";

describe("createClient", () => {
  beforeEach(() => {
    document.head.innerHTML = '<meta name="csrf-token" content="tok123">';
  });
  afterEach(() => vi.restoreAllMocks());

  it("sends the CSRF token and the idempotency key on writes", async () => {
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("{}", { status: 200 }));
    const api = createClient("/dashboard/api");
    await api.post("/payments/p1/refunds", { amount_minor: 1 }, { idempotencyKey: "k1" });
    const headers = fetchMock.mock.calls[0][1]!.headers as Record<string, string>;
    expect(headers["X-CSRF-Token"]).toBe("tok123");
    expect(headers["Idempotency-Key"]).toBe("k1");
  });

  it("turns the error envelope into an ApiFailure", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ error: { code: "forbidden", message: "no", retriable: false } }), { status: 403 }),
    );
    await expect(createClient("/dashboard/api").get("/x")).rejects.toMatchObject({ status: 403, code: "forbidden" });
  });

  it("on step_up_required asks the handler, then retries once with the same key", async () => {
    const fetchMock = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValueOnce(new Response(JSON.stringify({ error: { code: "step_up_required", message: "" } }), { status: 401 }))
      .mockResolvedValueOnce(new Response("{}", { status: 200 }));
    const api = createClient("/dashboard/api");
    api.onStepUp(async () => true);
    await api.post("/api_keys", { name: "x" }, { idempotencyKey: "same" });
    expect(fetchMock).toHaveBeenCalledTimes(2);
    const second = fetchMock.mock.calls[1][1]!.headers as Record<string, string>;
    expect(second["Idempotency-Key"]).toBe("same");
  });

  it("calls the sign-in handler on a plain 401", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ error: { code: "unauthenticated", message: "" } }), { status: 401 }),
    );
    const api = createClient("/dashboard/api");
    const onSignIn = vi.fn();
    api.onUnauthenticated(onSignIn);
    await expect(api.get("/me")).rejects.toBeInstanceOf(ApiFailure);
    expect(onSignIn).toHaveBeenCalled();
  });
});
```

```ts
// app/frontend/shared/http.ts
// One client per area. The server enforces everything; this only carries
// the CSRF token and the idempotency key, and routes 401s to the right place.
export class ApiFailure extends Error {
  constructor(
    public status: number,
    public code: string,
    message: string,
    public retriable = false,
    public details: Record<string, unknown> = {},
  ) {
    super(message);
  }
}

type Options = { idempotencyKey?: string; poll?: boolean };
type Handler = () => Promise<boolean>;

function csrfToken(): string {
  return document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content ?? "";
}

export function createClient(base: string) {
  let stepUp: Handler = async () => false;
  let unauthenticated: () => void = () => {};

  async function request<T>(method: string, path: string, body?: unknown, opts: Options = {}, retried = false): Promise<T> {
    const headers: Record<string, string> = { Accept: "application/json" };
    if (method !== "GET") {
      headers["Content-Type"] = "application/json";
      headers["X-CSRF-Token"] = csrfToken();
    }
    if (opts.idempotencyKey) headers["Idempotency-Key"] = opts.idempotencyKey;
    if (opts.poll) headers["X-Poll"] = "1";

    const res = await fetch(`${base}${path}`, {
      method,
      headers,
      credentials: "same-origin",
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    if (res.status === 204) return undefined as T;

    const text = await res.text();
    const json = text ? JSON.parse(text) : {};
    if (res.ok) return json as T;

    const err = json.error ?? {};
    const failure = new ApiFailure(res.status, err.code ?? "error", err.message ?? res.statusText, !!err.retriable, err.details ?? {});
    if (res.status === 401 && failure.code === "step_up_required" && !retried && (await stepUp())) {
      return request<T>(method, path, body, opts, true);
    }
    if (res.status === 401 && failure.code !== "step_up_required") unauthenticated();
    throw failure;
  }

  return {
    get: <T>(path: string, opts?: Options) => request<T>("GET", path, undefined, opts),
    post: <T>(path: string, body?: unknown, opts?: Options) => request<T>("POST", path, body, opts),
    put: <T>(path: string, body?: unknown, opts?: Options) => request<T>("PUT", path, body, opts),
    patch: <T>(path: string, body?: unknown, opts?: Options) => request<T>("PATCH", path, body, opts),
    delete: <T>(path: string, opts?: Options) => request<T>("DELETE", path, undefined, opts),
    onStepUp(handler: Handler) {
      stepUp = handler;
    },
    onUnauthenticated(handler: () => void) {
      unauthenticated = handler;
    },
  };
}

export type ApiClient = ReturnType<typeof createClient>;
```

**Step 3: Idempotency key per modal**

```ts
// app/frontend/shared/useIdempotencyKey.test.ts
import { describe, expect, it } from "vitest";
import { useIdempotencyKey } from "./useIdempotencyKey";

describe("useIdempotencyKey", () => {
  it("keeps one key across retries and makes a new one when the modal reopens", () => {
    const { key, renew } = useIdempotencyKey();
    const first = key.value;
    expect(key.value).toBe(first); // a retry reads the same key
    renew(); // modal opened again: a new intent
    expect(key.value).not.toBe(first);
  });
});
```

```ts
// app/frontend/shared/useIdempotencyKey.ts
import { ref } from "vue";

// One key per user intent (DECISIONS #3): create when the modal opens,
// reuse on every retry of that submit, renew only when the modal reopens.
export function useIdempotencyKey() {
  const key = ref(crypto.randomUUID());
  return { key, renew: () => (key.value = crypto.randomUUID()) };
}
```

**Step 4: USER WRITES `pollIntervalFor`**

Create the file with the signature and hand it to the user:

```ts
// app/frontend/shared/pollInterval.ts
// How often a payment page refetches, chosen from the payment's state.
// Return false to stop polling.
export type PaymentState =
  | "pending" | "requires_action" | "authorized" | "unknown" | "captured"
  | "canceled" | "failed" | "part_refunded" | "refunded";

export function pollIntervalFor(state: PaymentState): number | false {
  // TODO(user): 5-10 lines. Decide:
  // - which states are settled enough to stop polling (terminal ones surely;
  //   what about authorized, captured and part_refunded, which change only
  //   when someone acts or a refund settles?);
  // - how fast `pending` polls (the worker usually answers within seconds);
  // - how fast `unknown` polls. The sweeper first re-checks after 2 minutes and
  //   then backs off (DECISIONS #13), so polling it every second only costs
  //   requests; too slow and the page looks frozen when it resolves.
  // Trade-off: faster feels live but multiplies load by every open tab.
  // (useLiveQuery already pauses when the tab is hidden.)
  throw new Error("pollIntervalFor not written yet");
}
```

```ts
// app/frontend/shared/pollInterval.test.ts
import { describe, expect, it } from "vitest";
import { pollIntervalFor } from "./pollInterval";

describe("pollIntervalFor", () => {
  it("stops for terminal states", () => {
    for (const s of ["canceled", "failed", "refunded"] as const) expect(pollIntervalFor(s)).toBe(false);
  });

  it("keeps polling while the outcome is unknown, at a sane rate", () => {
    for (const s of ["pending", "unknown"] as const) {
      const ms = pollIntervalFor(s);
      expect(ms).not.toBe(false);
      expect(ms).toBeGreaterThanOrEqual(1000);
      expect(ms).toBeLessThanOrEqual(30000);
    }
  });
});
```

Continue once `npx vitest run app/frontend/shared/pollInterval.test.ts` passes.

**Step 5: `useLiveQuery`**

```ts
// app/frontend/shared/useLiveQuery.ts
import { useQuery, type QueryKey } from "@tanstack/vue-query";
import { computed, type MaybeRef, unref } from "vue";

// Polling in one place (design §1): the interval comes from the data, and
// TanStack pauses it while the tab is hidden. Action Cable can replace this
// composable later without touching a page.
export function useLiveQuery<T>(
  key: MaybeRef<QueryKey>,
  fetcher: (poll: boolean) => Promise<T>,
  intervalFor: (data: T) => number | false,
) {
  let first = true;
  return useQuery({
    queryKey: computed(() => unref(key)),
    queryFn: () => {
      const poll = !first;
      first = false;
      return fetcher(poll);
    },
    refetchInterval: (query) => (query.state.data ? intervalFor(query.state.data as T) : false),
    refetchIntervalInBackground: false,
  });
}
```

**Step 6: Money formatting**

```ts
// app/frontend/shared/money.ts
// Minor units → display string. Exponents mirror app/lib/currency.rb.
const EXPONENT: Record<string, number> = { EUR: 2, GBP: 2, USD: 2, THB: 2, VND: 0, IDR: 0 };

export function formatMoney(minor: number, currency: string): string {
  const exp = EXPONENT[currency] ?? 2;
  return new Intl.NumberFormat("en", { style: "currency", currency, minimumFractionDigits: exp, maximumFractionDigits: exp })
    .format(minor / 10 ** exp);
}

export function toMinor(major: string, currency: string): number {
  const exp = EXPONENT[currency] ?? 2;
  return Math.round(Number(major) * 10 ** exp);
}
```

Before writing `money.ts`, check `app/lib/currency.rb` for the real exponents and correct the table. Add `money.test.ts` for EUR 2500 → "€25.00" and VND 500000 → "₫500,000", plus `toMinor("12.34","EUR") === 1234`.

**Step 7: Run and commit**

Run: `npm run --silent typecheck && npm run --silent lint && npx vitest run`
Expected: PASS.

```bash
bin/check && git add app/frontend package.json package-lock.json && \
  git commit -m "Add the UI HTTP client, idempotency keys, live queries and money formatting"
```

---

### Task 19: Merchant pages

**Files:**
- Create: `app/frontend/merchant/api.ts`, `app/frontend/merchant/router.ts`, `app/frontend/merchant/useMe.ts`
- Create: `app/frontend/merchant/layouts/AppLayout.vue` (nav by permission, mode banner and toggle, sign out)
- Create: `app/frontend/merchant/components/StepUpDialog.vue`, `ConfirmDialog.vue`, `RefundDialog.vue`, `CaptureDialog.vue`, `ErrorBanner.vue`, `StatusBadge.vue`, `Timeline.vue`
- Create pages under `app/frontend/merchant/pages/`: `SignIn.vue`, `AcceptInvitation.vue`, `EnrolOtp.vue`, `Home.vue`, `Payments.vue`, `PaymentDetail.vue`, `Balance.vue`, `ApiKeys.vue`, `Webhooks.vue`, `Events.vue`, `Team.vue`, `SecurityHistory.vue`, `Profile.vue`, `NotFound.vue`
- Modify: `app/frontend/entrypoints/merchant.ts`, `app/frontend/merchant/App.vue`
- Test: `app/frontend/merchant/components/RefundDialog.test.ts`, `app/frontend/merchant/layouts/AppLayout.test.ts`

**Step 1: Wiring**

```ts
// app/frontend/merchant/api.ts
import { createClient } from "../shared/http";

export const api = createClient("/dashboard/api");
```

```ts
// app/frontend/entrypoints/merchant.ts
import { createApp } from "vue";
import { QueryClient, VueQueryPlugin } from "@tanstack/vue-query";
import "../styles.css";
import App from "../merchant/App.vue";
import { router } from "../merchant/router";
import { api } from "../merchant/api";

const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: 5_000 } } });
api.onUnauthenticated(() => {
  queryClient.clear();
  const next = router.currentRoute.value.fullPath;
  if (!next.startsWith("/sign-in")) router.push({ name: "sign-in", query: { next } });
});

createApp(App).use(router).use(VueQueryPlugin, { queryClient }).mount("#app");
```

```ts
// app/frontend/merchant/router.ts
import { createRouter, createWebHistory } from "vue-router";

// Every page is lazy-loaded; history mode under /dashboard, which Rails
// serves for any path (the shell route).
export const router = createRouter({
  history: createWebHistory("/dashboard"),
  routes: [
    { path: "/sign-in", name: "sign-in", component: () => import("./pages/SignIn.vue"), meta: { public: true } },
    { path: "/invitations/:token", name: "invitation", component: () => import("./pages/AcceptInvitation.vue"), meta: { public: true } },
    { path: "/enrol", name: "enrol", component: () => import("./pages/EnrolOtp.vue"), meta: { public: true } },
    {
      path: "/",
      component: () => import("./layouts/AppLayout.vue"),
      children: [
        { path: "", name: "home", component: () => import("./pages/Home.vue") },
        { path: "payments", name: "payments", component: () => import("./pages/Payments.vue"), meta: { permission: "payments.read" } },
        { path: "payments/:id", name: "payment", component: () => import("./pages/PaymentDetail.vue"), meta: { permission: "payments.read" } },
        { path: "balance", name: "balance", component: () => import("./pages/Balance.vue"), meta: { permission: "balance.read" } },
        { path: "developers/api-keys", name: "api-keys", component: () => import("./pages/ApiKeys.vue"), meta: { permission: "api_keys.read" } },
        { path: "developers/webhooks", name: "webhooks", component: () => import("./pages/Webhooks.vue"), meta: { permission: "webhooks.read" } },
        { path: "developers/events", name: "events", component: () => import("./pages/Events.vue"), meta: { permission: "webhooks.read" } },
        { path: "team", name: "team", component: () => import("./pages/Team.vue"), meta: { permission: "team.read" } },
        { path: "security", name: "security", component: () => import("./pages/SecurityHistory.vue"), meta: { permission: "security_history.read" } },
        { path: "profile", name: "profile", component: () => import("./pages/Profile.vue") },
      ],
    },
    { path: "/:rest(.*)*", name: "not-found", component: () => import("./pages/NotFound.vue"), meta: { public: true } },
  ],
});
```

```ts
// app/frontend/merchant/useMe.ts
import { useQuery } from "@tanstack/vue-query";
import { api } from "./api";
import { can, type Permission } from "../shared/can";

export type Me = {
  user: { id: string; email: string; name: string | null; role: string };
  merchant: { id: string; name: string };
  livemode: boolean;
  stepped_up_until: string | null;
  permissions: Permission[];
};

export function useMe() {
  const query = useQuery({ queryKey: ["me"], queryFn: () => api.get<Me>("/me") });
  const allowed = (p: Permission) => !!query.data.value && can(query.data.value.permissions, p);
  return { ...query, allowed };
}
```

`AppLayout.vue` loads `useMe()`. It renders nav links only for routes whose `meta.permission` passes `allowed`, and shows a fixed **"Test mode: you are looking at test data"** banner when `livemode` is false. The toggle calls `PUT /mode` and then `queryClient.invalidateQueries()` (every cached page belongs to the old mode). A router guard in the layout redirects to `home` when a route's `meta.permission` is not allowed. It also mounts `StepUpDialog` and registers `api.onStepUp(() => stepUpDialog.open())`, which resolves `true` after a successful `POST /session/step_up`.

**Step 2: Refund dialog (the pattern every money modal follows)**

```vue
<!-- app/frontend/merchant/components/RefundDialog.vue -->
<script setup lang="ts">
import { computed, ref, watch } from "vue";
import { DialogRoot, DialogPortal, DialogOverlay, DialogContent, DialogTitle } from "reka-ui";
import { api } from "../api";
import { ApiFailure } from "../../shared/http";
import { useIdempotencyKey } from "../../shared/useIdempotencyKey";
import { formatMoney, toMinor } from "../../shared/money";

const props = defineProps<{ open: boolean; paymentId: string; currency: string; refundableMinor: number }>();
const emit = defineEmits<{ "update:open": [boolean]; done: [] }>();

const { key, renew } = useIdempotencyKey();
const amount = ref("");
const reason = ref("");
const error = ref<string | null>(null);
const submitting = ref(false);

// A new intent each time the modal opens; retries of one submit reuse the key.
watch(() => props.open, (open) => {
  if (!open) return;
  renew();
  amount.value = String(props.refundableMinor / 10 ** (props.currency === "VND" || props.currency === "IDR" ? 0 : 2));
  reason.value = "";
  error.value = null;
});

const amountMinor = computed(() => toMinor(amount.value, props.currency));
const valid = computed(() => amountMinor.value > 0 && amountMinor.value <= props.refundableMinor && reason.value !== "");

async function submit() {
  submitting.value = true;
  error.value = null;
  try {
    await api.post(`/payments/${props.paymentId}/refunds`, { amount_minor: amountMinor.value, reason: reason.value }, { idempotencyKey: key.value });
    emit("done");
    emit("update:open", false);
  } catch (e) {
    error.value = e instanceof ApiFailure ? e.message : "Something went wrong. Try again.";
  } finally {
    submitting.value = false;
  }
}
</script>

<template>
  <DialogRoot :open="open" @update:open="emit('update:open', $event)">
    <DialogPortal>
      <DialogOverlay class="fixed inset-0 bg-black/40" />
      <DialogContent class="fixed left-1/2 top-1/2 w-[28rem] -translate-x-1/2 -translate-y-1/2 rounded bg-white p-6 shadow">
        <DialogTitle class="text-lg font-semibold">
          Refund payment
        </DialogTitle>
        <form class="mt-4 space-y-3" @submit.prevent="submit">
          <label class="block">
            Amount ({{ currency }})
            <input v-model="amount" inputmode="decimal" class="mt-1 w-full rounded border px-2 py-1" data-testid="refund-amount">
          </label>
          <p class="text-sm text-gray-600">
            Up to {{ formatMoney(refundableMinor, currency) }} can be refunded.
          </p>
          <label class="block">
            Reason
            <select v-model="reason" class="mt-1 w-full rounded border px-2 py-1" data-testid="refund-reason">
              <option value="" disabled>Choose a reason</option>
              <option value="requested_by_customer">Requested by customer</option>
              <option value="duplicate">Duplicate</option>
              <option value="fraudulent">Fraudulent</option>
              <option value="other">Other</option>
            </select>
          </label>
          <p v-if="error" role="alert" class="text-sm text-red-700">
            {{ error }}
          </p>
          <button type="submit" :disabled="!valid || submitting" class="rounded bg-red-700 px-3 py-1 text-white disabled:opacity-50" data-testid="refund-submit">
            Refund {{ formatMoney(amountMinor, currency) }}
          </button>
        </form>
      </DialogContent>
    </DialogPortal>
  </DialogRoot>
</template>
```

Replace the inline exponent check with a helper exported from `money.ts` (`exponentOf(currency)`) when writing it. The version above shows the behaviour only.

`RefundDialog.test.ts` (Vitest + @vue/test-utils, with `api.post` mocked through `vi.mock("../api")`) covers:
1. Opening prefills the refundable amount.
2. Submit is disabled without a reason.
3. A failed submit followed by a retry sends the **same** `idempotencyKey` both times.
4. Closing and reopening sends a **different** key.

**Step 3: The other pages**

Each page uses the endpoints from Tasks 6 to 15. Requirements the reviewer will check:

| Page | Must |
|---|---|
| `SignIn.vue` | Password step, then code step (with a "use a recovery code" switch). 423 shows the unlock time. On success go to `route.query.next` or home. Never say whether the email exists. |
| `AcceptInvitation.vue` | `GET invitations/:token` → name + password (min 12) → `accept` → go to `enrol`. Expired → a clear "ask for a new invitation" message. |
| `EnrolOtp.vue` | Render `qr_svg` with `v-html` (server-generated SVG, no user input) plus the URI for manual entry. Confirm the code. Show the 10 recovery codes **once**, with a "I have saved these" checkbox before continuing. |
| `Home.vue` | Attention counts linking to `payments?state=unknown` / `requires_action`, 7-day volume per currency, and balance only if `balance.read`. |
| `Payments.vue` | Filters (state, currency, date range) in the URL query; cursor "Load more"; an "Export CSV" link only with `payments.export` (href to `/dashboard/api/payments/export.csv?…`). |
| `PaymentDetail.vue` | `useLiveQuery(["payment", id], (poll) => api.get(\`/payments/${id}\`, { poll }), (p) => pollIntervalFor(p.state))`. `Timeline` shows every entry kind. The Capture, Cancel and Refund buttons render **only** when `can.capture` / `can.cancel` / `can.refund`. After any action, invalidate `["payment", id]`. `unknown` shows "We are confirming this payment with the PSP" and the time of the last check. 409/422 show the server message and refetch. |
| `Balance.vue` | Table per currency (available, reserved for refunds); a settlements table below with `settlements.read`. |
| `ApiKeys.vue` | List (redacted, status, last used). Create shows the secret once in a copy box with "This is the only time you will see it". Roll offers now / 24h / 7d. Revoke goes through `ConfirmDialog` with the key name typed to confirm. |
| `Webhooks.vue` | URL form, secret "Reveal" (step-up) and "Roll" (states the 24h overlap). |
| `Events.vue` | List with state filter; expanding a row shows its attempts; "Resend" only on dead events and only with `events.redeliver`. |
| `Team.vue` | Members and pending invitations; invite dialog (email + role, owner not offered); role select per member (hidden for self and owner); remove; "Transfer ownership" only with `ownership.transfer`. |
| `SecurityHistory.vue` | Cursor list and an "Export CSV" link. |
| `Profile.vue` | Change password, regenerate recovery codes (shown once). |

Accessibility baseline for every page: labelled inputs, focus moves into dialogs (Reka UI does this), `role="alert"` on errors, and nothing conveyed by colour alone (status badges carry text).

`AppLayout.test.ts`:
- A `viewer` sees Payments and Balance but not Developers or Team.
- `livemode: false` renders the test-mode banner.

**Step 4: Manual check**

Run `bin/vite dev` and `bin/rails s`. Accept the seeded owner invitation (Task 17, link printed by `bin/rails db:seed` or read in MailCatcher), enrol with an authenticator app (or `ROTP::TOTP.new(secret).now` in `bin/rails c`), then:
1. Invite a support user and accept that invite in a private window.
2. As support, refund a captured payment. The step-up dialog appears once, and the refund shows `pending` on the timeline.
3. Switch to test mode. The banner appears and the payments list changes.

Headless check that pages mount (macOS has no `timeout`; use `perl -e 'alarm shift; exec @ARGV' 30 …`, as in Phase 0 Task 12).

**Step 5: Commit**

```bash
bin/check && git add app/frontend package.json package-lock.json && git commit -m "Build the merchant dashboard pages"
```

---

### Task 20: Playwright flow 1: sign in with 2FA, then refund

**Files:**
- Create: `playwright.config.ts`, `e2e/merchant.spec.ts`, `lib/tasks/e2e.rake`
- Modify: `package.json` (`e2e` script), `.github/workflows/ci.yml` (e2e job), `eslint.config.js` (include `e2e/`)

**Step 1: Install**

```bash
npm install -D @playwright/test otpauth
npx playwright install chromium
```

**Step 2: Seed task (test environment only)**

```ruby
# lib/tasks/e2e.rake
# frozen_string_literal: true

namespace :e2e do
  desc "Seed a merchant, a support user with a known TOTP secret, and a captured payment (test env only)"
  task seed: :environment do
    abort "e2e:seed runs only in RAILS_ENV=test" unless Rails.env.test?

    merchant, = Merchant.create_with_api_key!(name: "E2E Merchant", default_currency: "EUR")
    MerchantUser.create!(merchant:, email: "support@e2e.test", role: "support", password: "e2e password 1234",
                         otp_secret: "JBSWY3DPEHPK3PXP", otp_enabled_at: Time.current, accepted_at: Time.current)
    payment = Payment.create!(merchant:, amount_minor: 2500, currency: "EUR", merchant_currency: "EUR", fx_rate: 1,
                              psp_name: "nordpay", psp_reference: Payment.generate_psp_reference, payment_method_token: "tok_visa")
    payment.transition!(:authorized, sort_key: Time.current, source: "worker")
    payment.transition!(:captured, sort_key: Time.current, source: "worker")
    Ledger.record_capture!(payment, 2500)
    puts payment.id
  end
end
```

Check `Payment#transition!` also books whatever `captured` requires. If other code books the ledger on capture (`BookCapture`), use that service instead of `Ledger.record_capture!` so the payment matches reality.

**Step 3: Config and spec**

```ts
// playwright.config.ts
import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "e2e",
  timeout: 60_000,
  use: { baseURL: "http://localhost:3210", trace: "retain-on-failure" },
  webServer: {
    command: "RAILS_ENV=test bin/rails db:test:prepare && RAILS_ENV=test bin/rails e2e:seed && RAILS_ENV=test bin/vite build && RAILS_ENV=test bin/rails s -p 3210",
    url: "http://localhost:3210/healthz",
    timeout: 120_000,
    reuseExistingServer: false,
  },
});
```

```ts
// e2e/merchant.spec.ts
import { expect, test } from "@playwright/test";
import { TOTP } from "otpauth";

const totp = new TOTP({ secret: "JBSWY3DPEHPK3PXP" });

test("support signs in with 2FA and refunds a captured payment", async ({ page }) => {
  await page.goto("/dashboard/payments");
  await expect(page).toHaveURL(/sign-in/);
  await page.getByLabel("Email").fill("support@e2e.test");
  await page.getByLabel("Password").fill("e2e password 1234");
  await page.getByRole("button", { name: "Continue" }).click();
  await page.getByLabel("Authenticator code").fill(totp.generate());
  await page.getByRole("button", { name: "Sign in" }).click();

  await page.getByRole("link", { name: /captured/i }).first().click();
  await page.getByRole("button", { name: "Refund" }).click();

  // Refund is sensitive: step-up. Wait for the next TOTP step so the code is not a replay.
  const wait = 30_000 - (Date.now() % 30_000) + 500;
  await page.waitForTimeout(wait);
  await page.getByLabel("Authenticator code").fill(totp.generate());
  await page.getByRole("button", { name: "Confirm" }).click();

  await page.getByTestId("refund-reason").selectOption("requested_by_customer");
  await page.getByTestId("refund-submit").click();
  await expect(page.getByText(/refund.*pending/i)).toBeVisible();
});
```

Match the labels to what Task 19 actually rendered. If they differ, change the page labels to these, because they are the accessible names users hear. If the step-up opens before the refund dialog in your implementation, reorder the steps; the assertion stays the same.

`package.json` scripts: `"e2e": "playwright test"`. `.gitignore`: `test-results/`, `playwright-report/`.

**Step 4: CI job**

Add to `.github/workflows/ci.yml` a job `e2e` (needs `check`) with the same Postgres/Redis services and env as `check`, plus `ruby/setup-ruby`, `actions/setup-node` (22, npm cache), `npm ci`, `bin/rails db:create db:schema:load`, `npx playwright install --with-deps chromium`, `npm run e2e`, and upload `playwright-report/` on failure.

**Step 5: Run and commit**

Run: `npm run e2e`
Expected: 1 passed.

```bash
bin/check && git add playwright.config.ts e2e lib/tasks/e2e.rake package.json package-lock.json .gitignore \
  .github/workflows/ci.yml eslint.config.js && git commit -m "Add the sign-in-then-refund end-to-end test"
```

---

### Task 21: Decisions, docs and full verification

**Step 1: DECISIONS.md #25: sessions and 2FA**, in the Decision / Rejected / Reason format:
- **Decision:**
  - Database-backed sessions (one polymorphic table) behind a signed, path-scoped cookie.
  - TOTP mandatory at enrolment, with 10 recovery codes.
  - Step-up for 10 minutes before any sensitive permission.
  - Lockout after 10 failures (password or code) for 30 minutes.
  - Idle timeout 15 minutes, absolute lifetime 12 hours.
- **Rejected:** Devise (a large surface for fixed roles and no self-sign-up); cookie-only sessions (cannot be revoked server-side); SMS codes (SIM swap).
- **Reason:** PCI DSS 8.2.8, 8.3.4 and 8.4; the use cases A-01 to A-07; revocation on role change and removal.

**Step 2: README:** the dashboard section (how to get the first owner in, what each role sees), and the e2e command. **RUNBOOK:** "A merchant user is locked out" (wait 30 minutes, or clear `locked_until` in a console with a ticket reference and record it in the audit log via `AuditEvent.record!`).

**Step 3: Full verification**
1. `bin/check`: all gates green.
2. `npm run e2e`: pass.
3. `docker compose up -d --build --wait`, `db:prepare db:seed`, `chaos:run[30]`: the one rule held. Accept the seeded owner invite from MailCatcher (`localhost:1080`), and walk the manual flow from Task 19 Step 4 on the compose stack.
4. Use @superpowers:verification-before-completion, then @superpowers:requesting-code-review with this plan as the requirements.

```bash
bin/check && git add DECISIONS.md README.md RUNBOOK.md && git commit -m "Record decision #25 and document the merchant dashboard"
```

---

## Carried from the Phase 0 review, handled here

| Review item | Task |
|---|---|
| Anonymous requests get 401 before any audit row | 4 |
| CSP on the UI pages | 16 |
| Test twin gets its own webhook endpoint | 13 |
| Unknown role gives an audited 403, not 500 | 4 |
| Authorization before idempotency | 5, 10 (spec) |

Deferred, still open: `psp_calls` body size cap, a `psp_calls` row for unexpected Faraday errors, and CancelPayment rolling back its own `psp_calls` rows. They belong to the operator view; see the Phase 2 plan.
