# frozen_string_literal: true

require 'active_record'
require 'itunes_parser'

module Am2plex
  # Raised for user-facing configuration/usage problems (missing files, bad
  # config). The CLI rescues these and prints them without a backtrace.
  class Error < StandardError; end
end

require_relative 'am2plex/version'
require_relative 'am2plex/match_text'
require_relative 'am2plex/database'
require_relative 'am2plex/models'
require_relative 'am2plex/config'
require_relative 'am2plex/importer'
require_relative 'am2plex/cli'
