# frozen_string_literal: true

require "itunes_parser"
require "json"
require "yaml"

require_relative "lib/db"
require_relative "lib/models"

ROOT = __dir__
config = YAML.load_file(File.join(ROOT, "config", "config.yml"))
dry_run = ARGV.include?("--dry-run")
default_date = DateTime.parse(config["default_date"])

if dry_run
  puts "Here is some information about your Plex server"
  puts "Found Account IDs: #{PlexMetadataItemView.distinct.pluck(:account_id).compact.join(", ")}"
  puts "Found Devices IDs: #{PlexMetadataItemView.distinct.pluck(:device_id).compact.join(", ")}\n\n"
else
  # prompt to continue
  puts "This will update the Plex database. Are you sure you want to continue? (y/n)"
  if gets.chomp != "y"
    puts "Exiting..."
    exit 0
  end
end

puts "Reading Apple Music tracks...\n\n"

parser = ItunesParser.new(file: File.join(ROOT, "config", "apple-music.xml"))
start_time = Time.now

apple_music_tracks = parser.tracks.values

# Keep only tracks that have been played or skipped enough to be worth syncing
puts "# of tracks from Apple Music: #{apple_music_tracks.size}\n\n"
puts "Filtering tracks based on these preferences...\n\n"
puts "Minimum plays: #{config["minimum_plays"]}"
puts "Minimum skips: #{config["minimum_skips"]}\n\n"
filtered_tracks = apple_music_tracks.select do |track|
  play_count = track["Play Count"]
  skip_count = track["Skip Count"]

  (play_count && play_count >= config["minimum_plays"]) ||
    (skip_count && skip_count >= config["minimum_skips"])
end

# Break up tracks based on whether they are from a compilation
puts "Splitting up compilation tracks...\n\n"
compilation_tracks_to_match, tracks_to_match =
  filtered_tracks.partition { |track| track["Compilation"] }

puts "# of normal tracks to sync: #{tracks_to_match.size}"
puts "# of compilation tracks to sync: #{compilation_tracks_to_match.size}\n\n"

puts "Comparing tracks...\n\n"

artists_not_found = []
albums_not_found = []
tracks_not_found = []
tracks_found = []

tracks_to_match.each do |apple_music_track|
  artist_name = apple_music_track["Album Artist"] || apple_music_track["Artist"]
  album_name = apple_music_track["Album"]
  track_name = apple_music_track["Name"]
  track_number = apple_music_track["Track Number"]

  next if artist_name.nil? || album_name.nil? || track_name.nil?
  next if artist_name.empty? || album_name.empty? || track_name.empty?
  next if artists_not_found.include?(artist_name)

  artist = PlexArtist.find_by_name(artist_name)
  if artist.nil?
    artists_not_found << artist_name
    next
  end

  next if albums_not_found.any? { |a| a[:album_name] == album_name }

  album = artist.albums.find_by_name(album_name)
  if album.nil?
    albums_not_found << { artist_name: artist_name, album_name: album_name }
    next
  end

  track = album.tracks.find_by_name(track_name)

  # try to match track by track number
  if track.nil? && track_number
    track = album.tracks.find_by(index: track_number)
    if track && dry_run
      puts "found track by track number"
      puts "source: #{track_name} - #{track_number} - #{album_name}- #{artist_name}"
      puts "found:  #{track.title} - #{track.index}\n\n"
    end
  end

  if track.nil?
    tracks_not_found << { artist_name: artist_name, album_name: album_name, track_name: track_name }
  else
    tracks_found << apple_music_track
  end
end

puts "Artists not found: #{artists_not_found.size}"
if dry_run
  puts "Writing missing artists to missing_artists.json...\n\n"
  artist_hash = artists_not_found.to_h { |artist| [artist, artist] }
  File.write(File.join(ROOT, "missing_artists.json"), JSON.pretty_generate(artist_hash))
  puts artists_not_found
  puts
end

puts "Albums not found: #{albums_not_found.size}"
if dry_run
  puts "Writing missing albums to missing_albums.json...\n\n"
  album_hash = albums_not_found.to_h { |album| [album[:album_name], album[:album_name]] }
  File.write(File.join(ROOT, "missing_albums.json"), JSON.pretty_generate(album_hash))
  puts albums_not_found.map { |a| "#{a[:artist_name]} - #{a[:album_name]}" }
  puts
end

puts "Tracks not found: #{tracks_not_found.size}"
if dry_run
  puts "Writing missing tracks to missing_tracks.json...\n\n"
  track_hash = tracks_not_found.to_h { |track| [track[:track_name], track[:track_name]] }
  File.write(File.join(ROOT, "missing_tracks.json"), JSON.pretty_generate(track_hash))
  puts tracks_not_found.map { |t| "#{t[:artist_name]} - #{t[:album_name]} - #{t[:track_name]}" }
  puts
end

puts "Tracks found: #{tracks_found.size} out of #{tracks_to_match.size}"
puts
puts "Time: #{Time.now - start_time} seconds"

exit 0 if dry_run

tracks_found.each do |apple_music_track|
  artist_name = apple_music_track["Album Artist"] || apple_music_track["Artist"]
  album_name = apple_music_track["Album"]
  track_name = apple_music_track["Name"]
  track_number = apple_music_track["Track Number"]
  play_count = apple_music_track["Play Count"]
  last_played_date = apple_music_track["Play Date UTC"] || apple_music_track["Date Modified"] || default_date
  skip_count = apple_music_track["Skip Count"]
  last_skipped_date = apple_music_track["Skip Date"] || apple_music_track["Date Modified"] || default_date
  track_rating = apple_music_track["Rating"] / 10 if apple_music_track["Rating"]
  album_rating = apple_music_track["Album Rating"] / 10 if apple_music_track["Album Rating"]

  artist = PlexArtist.find_by_name(artist_name)
  album = artist.albums.find_by_name(album_name)
  track = album.tracks.find_by_name(track_name)
  track = album.tracks.find_by(index: track_number) if track.nil? && track_number

  next unless track

  puts "Importing details of #{apple_music_track["Artist"]} - #{apple_music_track["Album"]} - #{apple_music_track["Name"]}"

  if config["import_plays"] && play_count&.positive?
    puts "Importing plays to plex database..."
    puts "Play Count: #{play_count}"
    puts "Last Played: #{last_played_date}\n\n"
    play_count.times do
      track.add_listen_at(last_played_date, config["account_id"], config["device_id"])
    end
  end

  if config["import_skips"] && skip_count&.positive?
    puts "Importing skips to plex database..."
    puts "Skip Count: #{skip_count}"
    puts "Last Skipped: #{last_skipped_date}\n\n"
    skip_count.times do
      track.add_skip_at(last_skipped_date, config["account_id"], config["device_id"])
    end
  end

  if config["import_track_ratings"] && track_rating
    puts "Importing track rating to plex database..."
    puts "Track Rating: #{track_rating}\n\n"
    track.set_rating(track_rating, config["account_id"])
  end

  if config["import_album_ratings"] && album_rating
    puts "Importing album rating to plex database..."
    puts "Album Rating: #{album_rating}\n\n"
    track.album.set_rating(album_rating, config["account_id"])
  end
end
