# frozen_string_literal: true

require_relative 'lib/am2plex/version'

Gem::Specification.new do |spec|
  spec.name    = 'am2plex'
  spec.version = Am2plex::VERSION
  spec.authors = ['Jeff Byrnes']
  spec.email   = ['thejeffbyrnes@gmail.com']

  spec.summary     = 'Import Apple Music play counts, skips, and ratings into a Plex library.'
  spec.description = <<~DESC
    am2plex reads an exported Apple Music library and a copy of your Plex
    SQLite database, matches tracks between them (by file path, falling back
    to album + title), and imports play counts, skip counts, last-played /
    last-skipped dates, and track/album ratings into Plex.
  DESC
  spec.homepage = 'https://github.com/jeffbyrnes/am2plex'
  spec.license  = 'MIT'

  spec.required_ruby_version = '>= 3.2'

  spec.metadata['homepage_uri']    = spec.homepage
  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = Dir.glob('lib/**/*.rb') + %w[README.md LICENSE]
  spec.bindir        = 'exe'
  spec.executables   = ['am2plex']
  spec.require_paths = ['lib']

  spec.add_dependency 'activerecord', '~> 8.0'
  spec.add_dependency 'itunes_parser', '~> 1.1'
  spec.add_dependency 'sqlite3', '~> 2.0'
end
