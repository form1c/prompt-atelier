# frozen_string_literal: true

# The entry point of the service, and the reason it exists is measured.
#
# A Windows service was registered with `nssm set … AppDirectory` and
# `nssm set … AppEnvironmentExtra`. Both calls reported success and **neither
# took effect**: read back afterwards, `AppDirectory` still held the directory
# of ruby.exe and `AppEnvironmentExtra` was empty. The service therefore ran in
# the wrong directory with none of the settings, and Bundler answered
# "command not found: puma".
#
# Why those two parameters do not take hold was not established. Rather than
# guess at it again, this script removes the need for them: it works out its
# own location, sets its own environment and changes into its own directory.
# What remains for the service manager is to start one executable with one
# argument, which is the part that demonstrably works.
#
# It is deliberately not the same file as `start_portable.rb`. That one is
# written for a person at a terminal: it takes a backup, forwards Ctrl+C to a
# process group and prints an address to open. A service has no terminal, and
# every one of those would be wrong here.

require_relative 'common'

module PromptAtelier
  module ServiceRun
    extend Script

    module_function

    # **Returned rather than set, so that it can be examined.**
    #
    # The case that covered this used to read the source of this file and look
    # for the string `ENV['BUNDLE_PATH']`. That stays green over code inside a
    # dead branch, over a commented-out line and over a mention in a comment. A
    # value a test can compare is worth more than a line a test can find.
    def service_environment
      {
        'RACK_ENV'          => 'production',
        'BUNDLE_GEMFILE'    => gemfile,
        'BUNDLE_PATH'       => File.join(app_dir, 'vendor', 'bundle'),
        'BUNDLE_APP_CONFIG' => File.join(app_dir, '.bundle'),
        'BUNDLE_WITHOUT'    => 'development:test'
      }
    end

    # The server, taken from the loaded specification. Needs the bundle to be
    # set up, so it is called after `activate_gems!` and not before.
    def puma_executable = Gem.bin_path('puma', 'puma')

    def run(_argv = [])
      # Everything Bundler would otherwise look for relative to a home
      # directory. A service does not run under the account that installed it,
      # so nothing here may be left to be discovered.
      service_environment.each { |name, value| ENV[name] = value }

      Dir.chdir(root)
      activate_gems!

      # **Not `bundle exec puma`, and this is the whole point of the file.**
      #
      # `bundle exec` looks the command up on the PATH, after putting the
      # bundle's own bin directory in front of it. Measured on a Windows
      # machine: that bin directory did not exist, because the Ruby there is a
      # user-scoped RubyInstaller whose built-in defaults carry
      # `--bindir C:/Users/<name>/AppData/Local/Microsoft/WindowsApps`. Every
      # gem executable of the installation therefore landed in a directory
      # belonging to one person. The account the service runs under does not
      # have it on its PATH, so `bundle exec` answered "command not found:
      # puma" while the same command run by that person worked.
      #
      # Putting that directory on the PATH would fix it for one account on one
      # machine, and it would make an installation that calls itself portable
      # depend on somebody's profile. `Gem.bin_path` asks the loaded
      # specification instead and answers with the file inside the bundle. No
      # PATH is involved at any point.
      ARGV.replace(['-C', puma_config])
      load puma_executable
    end

  end
end

PromptAtelier::ServiceRun.run(ARGV) if $PROGRAM_NAME == __FILE__
