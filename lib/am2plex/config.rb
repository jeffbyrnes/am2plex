# frozen_string_literal: true

require 'yaml'
require 'json'
require 'date'

module Am2plex
  # Loads the YAML config and exposes it to the rest of the app. All file paths
  # in the config (the library export, the Plex DB, the optional mapping files)
  # are resolved relative to the config file's own directory, so you can keep
  # everything together and run `am2plex` from anywhere.
  class Config
    # Tuning defaults applied when a key is absent from the YAML.
    DEFAULTS = {
      'minimum_plays' => 3,
      'minimum_skips' => 2,
      'import_plays' => true,
      'import_skips' => true,
      'import_track_ratings' => true,
      'import_album_ratings' => true
    }.freeze

    def self.load(path)
      new(path)
    end

    def initialize(path)
      raise Error, "Config file not found: #{path}" unless File.exist?(path)

      @dir = File.dirname(File.expand_path(path))
      @data = DEFAULTS.merge(YAML.safe_load_file(path) || {})
    end

    # Raw setting lookup (minimum_plays, account_id, import_* flags, ...).
    def [](key)
      @data[key]
    end

    def library_path
      require_path('library')
    end

    def database_path
      require_path('database')
    end

    def artist_mapping
      load_mapping('artist_mapping')
    end

    def album_mapping
      load_mapping('album_mapping')
    end

    def track_mapping
      load_mapping('track_mapping')
    end

    def default_date
      DateTime.parse(@data.fetch('default_date', DateTime.now.to_s))
    end

    private

    # Resolve a configured path (absolute, or relative to the config file's dir).
    def resolve(key)
      value = @data[key]
      return nil if value.nil? || value.to_s.empty?

      File.absolute_path?(value) ? value : File.join(@dir, value)
    end

    # A path that must be present and exist (library export, Plex DB).
    def require_path(key)
      path = resolve(key)
      raise Error, "Config is missing the '#{key}' path" if path.nil?
      raise Error, "#{key} file not found: #{path}" unless File.exist?(path)

      path
    end

    # An optional mapping file: absent or unreadable simply means "no mappings".
    def load_mapping(key)
      path = resolve(key)
      return {} if path.nil? || !File.exist?(path)

      JSON.parse(File.read(path))
    end
  end
end
