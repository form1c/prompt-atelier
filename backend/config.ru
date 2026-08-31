# frozen_string_literal: true

# Rack entry point. Loaded by Puma through the `rackup` line in
# config/puma.rb (Requirements 18.4).
#
# This is not an executable Ruby file. `ruby config.ru` aborts with
# NoMethodError because `run` comes from Rack::Builder, not from the main
# object (BT-18, TF-642). The only supported start is:
#
#   BUNDLE_GEMFILE=<app>/Gemfile bundle exec puma -C <app>/config/puma.rb

require_relative 'app'

# Installation directory: one level above backend/ resp. app/.
root = File.expand_path('..', __dir__)

def abort_with(lines, closing_key)
  warn ''
  lines.each { |line| warn "  #{line}" }
  warn ''
  warn "  #{PromptAtelier::I18n.t_safe(closing_key, 'Start abgebrochen.')}"
  warn ''
  # exit! rather than exit: Puma loads this file inside a rescue, catches the
  # SystemExit and appends "! Unable to load application: SystemExit: exit".
  # That line says nothing and pushes the message that matters out of sight.
  exit!(1)
end

begin
  PromptAtelier::App.boot!(root: root)
rescue PromptAtelier::Configuration::Error => e
  abort_with(e.problems, 'config.aborted')
rescue PromptAtelier::SchemaGuard::Mismatch => e
  abort_with([e.message], 'startup.aborted')
end

PromptAtelier::App.configuration.notes.each { |line| warn "  #{line}" }

run PromptAtelier::App
