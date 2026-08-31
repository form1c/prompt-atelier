# frozen_string_literal: true

require_relative '../services/migration'

# Product settings that the administration can change (FA-910).
#
# The configuration file holds two kinds of value that have nothing in common
# beyond living in the same file:
#
#   **Operating values** — address, port, paths, the
#   trusted proxies, whether HTTPS is forced. They describe the machine. A
#   wrong one takes the instance off the network, and the screen on which the
#   mistake was made is then unreachable — with the port that is literally so.
#   Some of them are also a way to grant oneself rights: whoever can widen
#   `trusted_proxies` disables the login limit and can write any address into
#   the very log this screen shows. These stay in config.yml.
#
#   **Product values** — whether people may register, how long things are
#   kept, how many login attempts are allowed. They describe the product. A
#   wrong one takes nothing off the network, and none of them needs a restart,
#   because the application reads its configuration on every request anyway.
#   These belong where the person who decides them already is.
#
# The table therefore holds only the second kind. It is read over the file, so
# config.yml keeps saying what an installation starts with while the table
# says what it is running on now.
PromptAtelier::Migration.register('004_settings') do
  <<~SQL
    CREATE TABLE settings (
      key        TEXT     PRIMARY KEY,
      value_json TEXT     NOT NULL,
      updated_at DATETIME NOT NULL,
      updated_by INTEGER  REFERENCES users(id) ON DELETE SET NULL
    );
  SQL
end
