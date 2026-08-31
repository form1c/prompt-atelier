# Puma configuration (Requirements 18.4)
#
# This file runs unchanged in both directory layouts from 18.2:
#
#   delivery      <installation>/app/config/puma.rb         -> root = <installation>
#   development   PromptAtelier/project/backend/config/puma.rb -> root = .../project
#
# In both cases config/config.yml and data/ sit at the same relative place.
# That is why project/ is the installation directory during development.
#
# Both paths are derived from this file's own location rather than from fixed
# names: the application directory is called backend/ during development and
# app/ after building. A hard-coded 'app' would be wrong in development.
#
# Host and port live in config.yml only. No start command and no service unit
# may state them again (BT-19) — otherwise there would be two sources of
# truth, and whoever changes the configuration keeps starting on the old port
# and looks for the fault in the wrong place.

require 'yaml'

# backend/ resp. app/ — the directory containing config.ru.
application_dir = File.expand_path('..', __dir__)
# Installation directory: one level above that.
install_root    = File.expand_path('..', application_dir)

config_file   = File.join(install_root, 'config', 'config.yml')
template_file = File.join(install_root, 'config', 'config.example.yml')

# Puma starts before the application does. A missing configuration would abort
# here with a bare exception, but the message should say what to do. The full
# validation is done later by the application itself
# (services/configuration.rb) — only host and port are needed here.
unless File.exist?(config_file) || File.exist?(template_file)
  warn "PromptAtelier: neither #{config_file} nor #{template_file} exists. " \
       'Run "install" first.'
  exit 1
end

read_yaml = lambda do |path|
  next {} unless File.exist?(path)

  YAML.safe_load(File.read(path, encoding: 'UTF-8'), permitted_classes: [], aliases: false) || {}
end

# The template supplies the defaults, config.yml overrides them — the same
# rule the application applies (18.4). Reading config.yml alone would be
# wrong in a way that is easy to miss: with `server.host` absent the bind
# string becomes "tcp://:9292", and Puma then listens on 0.0.0.0 instead of
# 127.0.0.1. The application would be reachable from the whole network
# although the configuration never said so. Found by TF-645b.
defaults = read_yaml.call(template_file)
own      = read_yaml.call(config_file)
cfg      = defaults.merge(own) do |_key, a, b|
  a.is_a?(Hash) && b.is_a?(Hash) ? a.merge(b) : b
end

host = cfg.dig('server', 'host')
port = cfg.dig('server', 'port')

if host.to_s.strip.empty? || port.nil?
  warn "PromptAtelier: server.host or server.port missing in #{config_file} " \
       "and in #{template_file}. Refusing to guess."
  exit 1
end

bind    "tcp://#{host}:#{port}"
threads 1, 8
environment ENV.fetch('RACK_ENV', 'production')

directory install_root                            # base for all relative paths

# Required: otherwise Puma looks for config.ru in the working directory, which
# `directory` has just set to the installation root. It is not there. Without
# this line Puma binds the port and then aborts with
# "No application configured, nothing to run" (finding P-2, TF-645c).
rackup File.join(application_dir, 'config.ru')

pidfile File.join(install_root, 'data', 'promptatelier.pid')
