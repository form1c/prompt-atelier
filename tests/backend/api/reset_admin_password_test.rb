# frozen_string_literal: true

require_relative '../../test_helper'
require 'open3'
require 'services/password'
require 'services/accounts'
require 'services/workspaces'
require 'services/sessions'

# TF-631 / BT-13 / A-25 — the way back when nobody can sign in any more.
#
# **This file exists because the acceptance protocol was written.** Going
# through A-01 to A-32 one by one and asking "what proves this?" turned up one
# criterion with nothing behind it: A-25 named TF-631, TF-631 named
# `reset_admin_password`, and no test had ever run that script. It had been
# written in AP-05 — pulled forward, because without an e-mail reset (E-13)
# there is no other way back — and left unexercised ever since.
#
# That is the worst place for a gap. The path is used exactly once in the life
# of an instance, by somebody who is already locked out, on a bad day. If it
# does not work then, there is no second way.
#
# Three things have to happen and are checked separately, because any one of
# them could be lost without the other two noticing:
#
#   * the password really changes, and the account is unlocked
#   * every session of the account is dropped (SEC-15) — a captured token must
#     not survive the reset
#   * the run is written to the audit log (SEC-09) — an emergency path that
#     leaves no trace cannot be told apart from an attack
class ResetAdminPasswordTest < PromptAtelier::TestCase
  NEW_PASSWORD = 'Neues-Notfall-Kennwort-1'

  # **A throwaway installation, and the script is started from inside it.**
  #
  # The first version ran `project/scripts/lib/reset_admin_password.rb` with
  # `chdir:` pointing at the throwaway directory — and reset the password of an
  # account in the **developer's own database**. `Script.root` is derived from
  # the script file's own location (18.2), which is right for a delivered
  # installation and means the working directory decides nothing at all. A copy
  # of `scripts/` therefore has to live in the throwaway installation, exactly
  # as `package_test` does it.
  def setup
    super
    @dir = build_installation(app_dir_name: 'app')
    FileUtils.cp_r(File.join(CODE_ROOT, 'scripts'), @dir)
  end

  # --- the ordinary case ------------------------------------------------------

  def test_it_sets_the_password_of_the_only_instance_administrator
    admin = create_admin
    status, output = run_reset('--generate')

    assert_equal 0, status, output
    assert_includes output, admin[:email]

    reread = user(admin[:id])
    refute_equal admin[:password_hash], reread[:password_hash]
  end

  # `--generate` prints the password, and it has to be the one that now opens
  # the account. A run that announced one password and stored another would
  # lock the person out for good — and would look exactly like a success.
  def test_the_printed_password_is_the_one_that_opens_the_account
    admin = create_admin
    _, output = run_reset('--generate')

    printed = output[/[A-Za-z0-9]{20}/]
    refute_nil printed, 'no generated password in the output'
    assert PromptAtelier::Password.verify(printed, user(admin[:id])[:password_hash]),
           'the script said one password and stored another'
  end

  # FA-903: the reset is a way in, not a new permanent password. The next
  # sign-in has to demand a change.
  def test_the_account_must_change_its_password_afterwards
    admin = create_admin
    run_reset('--generate')

    assert user(admin[:id])[:must_change_pw]
  end

  # A locked-out administrator is often locked out because the account is
  # locked. Leaving the status alone would hand back a password that still
  # cannot be used.
  def test_a_locked_account_is_unlocked_again
    admin = create_admin
    with_db(@dir) { |db| db[:users].where(id: admin[:id]).update(status: 'locked') }

    run_reset('--generate')

    assert_equal 'active', user(admin[:id])[:status]
  end

  # SEC-15. Checked by counting the rows rather than by trusting the script's
  # own sentence about them.
  def test_every_session_of_the_account_is_dropped
    admin = create_admin
    with_db(@dir) do |db|
      2.times { insert_session(db, admin[:id]) }
      assert_equal 2, db[:sessions].where(user_id: admin[:id]).count
    end

    run_reset('--generate')

    with_db(@dir) do |db|
      assert_equal 0, db[:sessions].where(user_id: admin[:id]).count
    end
  end

  # SEC-09 and BT-13: the run leaves a trace. Without it, a reset and an
  # intrusion look the same afterwards.
  def test_the_run_is_written_to_the_audit_log
    admin = create_admin
    run_reset('--generate')

    with_db(@dir) do |db|
      entry = db[:audit_logs].where(action: 'password.reset_by_console').first

      refute_nil entry, 'the emergency path left no trace'
      assert_equal admin[:id], entry[:target_id]
    end
  end

  # --- the refusals -------------------------------------------------------------

  # Guessing would be the wrong kind of convenience: with two administrators
  # the script cannot know which one is meant, and picking one would reset a
  # password nobody asked about.
  def test_two_administrators_without_an_address_are_refused
    create_admin(email: 'erste@test')
    create_admin(email: 'zweite@test')

    status, output = run_reset('--generate')

    refute_equal 0, status
    assert_includes output, 'erste@test'
    assert_includes output, 'zweite@test'
  end

  def test_an_address_picks_the_account_even_with_two_administrators
    first = create_admin(email: 'erste@test')
    create_admin(email: 'zweite@test')

    status, = run_reset('erste@test', '--generate')

    assert_equal 0, status
    refute_equal first[:password_hash], user(first[:id])[:password_hash]
  end

  def test_an_unknown_address_is_refused_and_changes_nothing
    admin = create_admin
    status, output = run_reset('gibtesnicht@test', '--generate')

    refute_equal 0, status
    assert_includes output, 'gibtesnicht@test'
    assert_equal admin[:password_hash], user(admin[:id])[:password_hash]
  end

  def test_an_instance_without_an_administrator_is_refused
    status, output = run_reset('--generate')

    refute_equal 0, status
    refute_empty output.strip
  end

  # SEC-02 holds here too. The emergency path is the one place where somebody
  # under pressure would reach for something short, and it is also the one
  # place where nobody is watching.
  def test_a_password_below_the_policy_is_refused
    admin = create_admin
    status, output = run_reset(input: "kurz\nkurz\n")

    refute_equal 0, status
    refute_empty output.strip
    assert_equal admin[:password_hash], user(admin[:id])[:password_hash]
  end

  # Typed twice, and the two have to match — the same rule the browser follows.
  def test_two_different_entries_are_refused
    admin = create_admin
    status, = run_reset(input: "#{NEW_PASSWORD}\n#{NEW_PASSWORD}-anders\n")

    refute_equal 0, status
    assert_equal admin[:password_hash], user(admin[:id])[:password_hash]
  end

  private

  def create_admin(email: 'notfall@test')
    with_db(@dir) do |db|
      PromptAtelier::Accounts.create(db, name: 'Notfall', email: email,
                                         password: 'Ein-langes-Kennwort-99', instance_admin: true)
    end
  end

  def user(id) = with_db(@dir) { |db| db[:users][id: id] }

  # Through the real service, so the rows are the ones the application makes.
  def insert_session(db, user_id)
    PromptAtelier::Sessions.create(db, user_id: user_id)
  end

  # The script as a process, in the environment a shell would give it (testbed
  # rules 12 and 13) and **from inside the throwaway installation** (rule 17).
  # `--generate` skips the two password questions; a run without it is fed
  # through stdin, which is what `input:` is for.
  def run_reset(*arguments, input: nil)
    output, status = Open3.capture2e(
      script_env,
      RbConfig.ruby, File.join(@dir, 'scripts', 'lib', 'reset_admin_password.rb'),
      *arguments, chdir: @dir, stdin_data: input.to_s
    )
    [status.exitstatus, output]
  end
end
