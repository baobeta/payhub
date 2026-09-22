# typed: strict
# frozen_string_literal: true

# Keyset ("cursor") pagination over (created_at DESC, id DESC).
#
# Why not OFFSET: at 1,000,000 rows, OFFSET 900000 scans and discards
# 900,000 rows. A keyset predicate `(created_at, id) < ($1, $2)` hits the
# compound index and reads only the page. The cursor is the last row's
# (created_at, id), base64-encoded so it is opaque to the client and the
# encoding can change without breaking anyone.
#
# id is the tiebreak: created_at alone is not unique under concurrency, and
# without a total order a page boundary could skip or repeat rows.
module Cursor
  extend T::Sig

  class Invalid < StandardError; end

  MAX_LIMIT = 100
  DEFAULT_LIMIT = 25

  class Page < T::Struct
    const :records, T::Array[T.untyped]
    const :has_more, T::Boolean
    const :next_cursor, T.nilable(String)
  end

  class << self
    extend T::Sig

    sig { params(created_at: T.any(Time, ActiveSupport::TimeWithZone), id: String).returns(String) }
    def encode(created_at, id)
      Base64.urlsafe_encode64("#{created_at.utc.iso8601(6)}|#{id}", padding: false)
    end

    sig { params(cursor: String).returns([Time, String]) }
    def decode(cursor)
      raw = Base64.urlsafe_decode64(cursor)
      ts, id = raw.split("|", 2)
      raise Invalid, "malformed cursor" if ts.nil? || id.nil? || id.empty?

      [Time.iso8601(ts), id]
    rescue ArgumentError
      raise Invalid, "malformed cursor"
    end

    # `scope` must already be filtered to what the caller may see (e.g. one
    # merchant). We add ordering, the keyset predicate, and limit+1 to learn
    # has_more without a COUNT.
    sig { params(scope: T.untyped, after: T.nilable(String), limit: T.nilable(Integer)).returns(Page) }
    def paginate(scope, after: nil, limit: nil)
      per = (limit || DEFAULT_LIMIT).clamp(1, MAX_LIMIT)
      table = scope.table_name
      rel = scope.order(Arel.sql("#{table}.created_at DESC, #{table}.id DESC"))

      if after.present?
        ts, id = decode(after)
        rel = rel.where("(#{table}.created_at, #{table}.id) < (?, ?)", ts, id)
      end

      rows = rel.limit(per + 1).to_a
      has_more = rows.size > per
      rows = rows.first(per)
      last = rows.last
      Page.new(records: rows, has_more: has_more,
               next_cursor: has_more && last ? encode(last.created_at, last.id) : nil)
    end
  end
end
