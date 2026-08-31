# frozen_string_literal: true

require 'argon2'
require 'securerandom'
require 'set'
require_relative 'i18n'

module PromptAtelier
  # Password hashing and the password policy (SEC-01, SEC-02, SEC-07).
  module Password
    # SEC-01: at least 64 MiB of memory, 3 passes, parallelism 1.
    #
    # m_cost is the base-2 logarithm of the memory in KiB, not the memory
    # itself: 64 MiB = 65536 KiB = 2^16, hence 16. Getting this wrong is easy
    # and silent — m_cost: 64 would ask for 2^64 KiB. The resulting hash
    # carries "m=65536,t=3,p=1" in its header, which is what TF-501 reads back.
    MEMORY_COST = 16
    TIME_COST   = 3
    PARALLELISM = 1

    MINIMUM_LENGTH = 12
    MAXIMUM_LENGTH = 200 # bcrypt-style truncation is not a risk here, but an
                         # unbounded input would let one request occupy the
                         # hashing lock for a long time.

    WORDLIST_PATH = File.expand_path('../wordlists/common_passwords.txt', __dir__)

    # Guards every Argon2 call. Requirements 18.3: each hashing operation
    # claims at least 64 MiB, and Puma allows 8 threads — eight concurrent
    # logins would be 512 MiB and a cheap way to exhaust the machine from
    # outside. Serialising costs measurably more wall time under load (four
    # concurrent operations take about 510 ms instead of 190 ms) and is worth
    # it: the memory ceiling stays at one operation.
    LOCK = Mutex.new

    # A valid Argon2id hash of a random value that was discarded when this
    # constant was generated. Used when the account is unknown, so that
    # "no such user" costs the same as "wrong password" (SEC-07).
    #
    # Written out rather than computed, and that detail matters: generating it
    # lazily made the *first* unknown-account attempt in a process pay for
    # both the creation and the verification — measured at 252 ms against
    # 128 ms for a real check. The very first probe would have leaked exactly
    # what the dummy hash exists to hide.
    #
    # It is not a secret. It guards nothing; it consumes time.
    DUMMY_HASH = '$argon2id$v=19$m=65536,t=3,p=1$' \
                 'sfNa1ISvY+sUUef7u4t38w$sePLJ/BTYkCogRpPQtvFMM1LQOd0vKhyaOvm+DLd+b8'

    class << self
      def dummy_hash = DUMMY_HASH

      def create(plain)
        LOCK.synchronize do
          Argon2::Password.create(plain, t_cost: TIME_COST, m_cost: MEMORY_COST,
                                         p_cost: PARALLELISM)
        end
      end

      # Verifies a password against a hash. Never raises: a damaged or empty
      # hash in the database is a data problem, not a reason to hand the
      # caller a 500 — and a raised exception would itself be a timing signal.
      def verify(plain, hash)
        return false if plain.nil? || hash.nil? || hash.empty?

        LOCK.synchronize { Argon2::Password.verify_password(plain.to_s, hash) }
      rescue Argon2::ArgonHashFail, ArgumentError
        false
      end

      # Burns the same amount of time as a real verification without there
      # being an account. Called on the unknown-account path so both paths
      # cost one full Argon2id run (SEC-07).
      #
      # The return value is always false; it exists for its duration.
      def verify_dummy(plain)
        verify(plain.to_s, dummy_hash)
        false
      end

      # --- policy (SEC-02) ---------------------------------------------------

      # Returns the list of reasons the password is unacceptable — empty means
      # acceptable. A list rather than a boolean so the user learns everything
      # at once instead of one rule per attempt.
      def policy_violations(plain)
        value = plain.to_s
        problems = []

        # Codes, not sentences (AP-19). The rule knows what is wrong and what
        # number it depends on; who reads it, and in which language, is not its
        # business.
        problems << { code: 'too_short', params: { minimum: MINIMUM_LENGTH } } if value.length < MINIMUM_LENGTH
        problems << { code: 'too_long', params: { maximum: MAXIMUM_LENGTH } } if value.length > MAXIMUM_LENGTH
        problems << { code: 'too_common' } if common?(value)

        problems
      end

      def acceptable?(plain) = policy_violations(plain).empty?

      # The same refusals as sentences, for the console (E-12). The scripts
      # have no browser in front of them to turn a code into words, and
      # `install` prints these while somebody is typing a password — a line
      # reading `{:code=>"too_short"}` would tell that person nothing.
      def policy_sentences(plain)
        policy_violations(plain).map do |problem|
          I18n.t("password.#{problem[:code]}", **problem.fetch(:params, {}))
        end
      end

      # Case-insensitive membership. Deliberately not a "strength estimator":
      # SEC-02 asks for a frequency list, and a scoring heuristic would reject
      # good passphrases while letting through the next variant of the same
      # bad idea.
      def common?(plain)
        wordlist.include?(plain.to_s.downcase)
      end

      def wordlist
        @wordlist ||= File.readlines(WORDLIST_PATH, chomp: true, encoding: 'UTF-8')
                          .reject { |line| line.empty? || line.start_with?('#') }
                          .map(&:downcase)
                          .to_set
      end

      # For tests that need to observe the policy with a known list.
      def reset!
        @wordlist = nil
      end
    end
  end
end
