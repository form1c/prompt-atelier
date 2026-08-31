# frozen_string_literal: true

require 'date'

module PromptAtelier
  # The daily clear-out (FA-706, SEC-16).
  #
  # Two reasons it exists, and they pull in the same direction: without fixed
  # limits the database grows without end, and personal data — IP addresses and
  # user agents in `sessions` and `audit_logs` — would be kept for ever.
  #
  # Every limit is configurable (18.4). What is not configurable is the shape
  # of the rule for revisions, and that shape is the part worth reading twice:
  # **the minimum age wins over the count**. Fifty revisions is a storage
  # limit, ninety days is a promise about being able to go back — and a prompt
  # somebody worked on all week must not lose Monday because Friday made it the
  # fifty-first.
  module Retention
    DEFAULTS = {
      'revisions_per_prompt' => 50,
      'revisions_min_days' => 90,
      'trash_days' => 30,
      'audit_months' => 12,
      'audit_max_entries' => 200_000,
      'login_attempts_days' => 7
    }.freeze

    class << self
      # Returns what it removed, per kind. The caller writes that to the log —
      # FA-706 asks for a summary per run, and a run that reports nothing is
      # indistinguishable from one that did not happen.
      def sweep(db, config: nil, now: Time.now)
        {
          'revisions' => sweep_revisions(db, limits(config), now),
          'prompts' => sweep_trash(db, limits(config), now),
          'audit' => sweep_audit(db, limits(config), now),
          'sessions' => sweep_sessions(db, now),
          'login_attempts' => sweep_attempts(db, limits(config), now)
        }
      end

      # The configuration is consulted through its own lookup (`config[…]`),
      # which answers nil for anything it does not carry. The defaults here
      # are for callers without one — the cleanup has to work in a test and in
      # a script, not only inside the running application.
      def limits(config)
        DEFAULTS.to_h { |key, fallback| [key, config&.[]("retention.#{key}") || fallback] }
      end

      # The rule with the two halves. Kept: everything inside the minimum age,
      # **plus** the newest N of what is older. Deleting by count alone would
      # break the promise; deleting by age alone would let one busy prompt fill
      # the table.
      def sweep_revisions(db, limits, now)
        cutoff = now - (limits['revisions_min_days'] * 86_400)
        keep = limits['revisions_per_prompt']
        removed = 0

        db[:prompt_revisions].distinct.select_map(:prompt_id).each do |prompt_id|
          doomed = db[:prompt_revisions].where(prompt_id: prompt_id)
                                        .where { created_at < cutoff }
                                        .reverse(:created_at)
                                        .offset(keep)
                                        .select_map(:id)
          next if doomed.empty?

          removed += db[:prompt_revisions].where(id: doomed).delete
        end

        removed
      end

      # FA-703: thirty days in the bin, then gone for good — with the
      # revisions, which is what `Prompts.purge` does for a single one.
      # The revisions go with them, and the schema is what sees to it:
      # `prompt_revisions.prompt_id` cascades on delete (14.1). An explicit
      # delete stood here first and a mutation probe showed it could go
      # without a test noticing — it was doing the foreign key's work twice.
      def sweep_trash(db, limits, now)
        cutoff = now - (limits['trash_days'] * 86_400)

        db[:prompts].exclude(deleted_at: nil).where { deleted_at < cutoff }.delete
      end

      # Months rather than days, because the requirement says months. Counted
      # by calendar rather than as 30-day blocks: "twelve months" and "365
      # days" part company in a leap year, and the document names the former.
      def sweep_audit(db, limits, now)
        cutoff = shift_months(now, -limits['audit_months'])
        removed = db[:audit_logs].where { created_at < cutoff }.delete

        removed + trim_audit(db, limits['audit_max_entries'])
      end

      # The last brake before a full disk, below the twelve-month rule and
      # never instead of it.
      #
      # It has to be said plainly what this is: a ring buffer, and therefore
      # the very mechanism by which somebody could push evidence out of the
      # log. It is safe only because the collapsing of SEC-07 stands in front
      # of it — refused login attempts no longer produce a row each, so the
      # cheap way of reaching this limit is gone. Loosening the one without
      # looking at the other turns this line into the weakness.
      #
      # Ordered by `id` and not by `created_at`: the id is the insertion order,
      # it is unique, and rows written in the same moment therefore have a
      # defined oldest one.
      def trim_audit(db, keep)
        surplus = db[:audit_logs].count - keep.to_i
        return 0 if surplus <= 0

        doomed = db[:audit_logs].order(:id).limit(surplus).select_map(:id)
        db[:audit_logs].where(id: doomed).delete
      end

      def shift_months(time, months)
        total = (time.year * 12) + (time.month - 1) + months
        year = total / 12
        month = (total % 12) + 1
        day = [time.day, days_in(year, month)].min

        Time.new(year, month, day, time.hour, time.min, time.sec, time.utc_offset)
      end

      def days_in(year, month)
        Date.new(year, month, -1).day
      end

      # Expired sessions hold an IP address and a user agent and are of no
      # further use once they cannot authenticate anything (SEC-16).
      def sweep_sessions(db, now)
        db[:sessions].where { expires_at < now }.delete
      end

      def sweep_attempts(db, limits, now)
        cutoff = now - (limits['login_attempts_days'] * 86_400)

        db[:login_attempts].where { attempted_at < cutoff }.delete
      end
    end
  end
end
