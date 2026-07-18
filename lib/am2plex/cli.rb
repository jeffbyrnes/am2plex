# frozen_string_literal: true

require 'optparse'

module Am2plex
  # Command-line entry point. Parses options, loads the config, connects to the
  # Plex DB, wires the manual mappings into the models, and runs the importer.
  module CLI
    module_function

    DEFAULT_CONFIG = 'config.yml'

    def start(argv)
      options = { config: DEFAULT_CONFIG, dry_run: false }
      parse!(argv, options)

      config = Config.load(options[:config])
      Database.connect(config.database_path)
      apply_mappings(config)

      Importer.new(config).run(dry_run: options[:dry_run])
    rescue Am2plex::Error => e
      warn "Error: #{e.message}"
      exit 1
    end

    def parse!(argv, options)
      OptionParser.new do |opts|
        opts.banner = <<~BANNER
          Import Apple Music play counts, skips, and ratings into a Plex library.

          Usage: am2plex [options]
        BANNER

        opts.on('-c', '--config PATH', "Path to the config file (default: #{DEFAULT_CONFIG})") do |path|
          options[:config] = path
        end
        opts.on('-n', '--dry-run', 'Preview matches and write reports without modifying the Plex DB') do
          options[:dry_run] = true
        end
        opts.on('-v', '--version', 'Print version and exit') do
          puts "am2plex #{VERSION}"
          exit
        end
        opts.on('-h', '--help', 'Print this help and exit') do
          puts opts
          exit
        end
      end.parse!(argv)
    end

    def apply_mappings(config)
      PlexMetadataItem.artist_mapping = config.artist_mapping
      PlexMetadataItem.album_mapping = config.album_mapping
      PlexMetadataItem.track_mapping = config.track_mapping
    end
  end
end
