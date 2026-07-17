# frozen_string_literal: true

require 'cgi'
require 'itunes_parser'
require 'json'
require 'yaml'

require_relative 'lib/db'
require_relative 'lib/models'

ROOT = __dir__
config = YAML.load_file(File.join(ROOT, 'config', 'config.yml'))
dry_run = ARGV.include?('--dry-run')
default_date = DateTime.parse(config['default_date'])

def write_missing(path, names)
  File.write(path, JSON.pretty_generate(names.uniq.to_h { |name| [name, name] }))
end

# Apple Music streaming tracks (HLS media, stored in .movpkg bundles) have no
# real local file, so they can never exist in a local Plex library. Only tracks
# backed by an actual audio file are worth trying to match.
def local_file?(track)
  return false if track['Track Type'] == 'Remote'
  return false if track['Kind'].to_s.include?('HLS')

  location = CGI.unescape(track['Location'].to_s).downcase.chomp('/')
  !location.empty? && !location.end_with?('.movpkg')
end

if dry_run
  puts 'Here is some information about your Plex server'
  puts "Found Account IDs: #{PlexMetadataItemView.distinct.pluck(:account_id).compact.join(', ')}"
  puts "Found Devices IDs: #{PlexMetadataItemView.distinct.pluck(:device_id).compact.join(', ')}\n\n"
else
  # prompt to continue
  puts 'This will update the Plex database. Are you sure you want to continue? (y/n)'
  if gets.chomp != 'y'
    puts 'Exiting...'
    exit 0
  end
end

puts "Reading Apple Music tracks...\n\n"

parser = ItunesParser.new(file: File.join(ROOT, 'config', 'apple-music.xml'))
start_time = Time.now

apple_music_tracks = parser.tracks.values

# Keep only tracks that have been played or skipped enough to be worth syncing
puts "# of tracks from Apple Music: #{apple_music_tracks.size}\n\n"
puts "Filtering tracks based on these preferences...\n\n"
puts "Minimum plays: #{config['minimum_plays']}"
puts "Minimum skips: #{config['minimum_skips']}\n\n"
played_tracks = apple_music_tracks.select do |track|
  play_count = track['Play Count']
  skip_count = track['Skip Count']

  (play_count && play_count >= config['minimum_plays']) ||
    (skip_count && skip_count >= config['minimum_skips'])
end

# Drop Apple Music streaming tracks up front: they have no local file, so they
# can't be in Plex and would only ever show up as noise in the "not found" list.
tracks_to_match, streaming_tracks = played_tracks.partition { |track| local_file?(track) }
puts "Excluding #{streaming_tracks.size} Apple Music streaming tracks (no local file)\n\n"

# Compilations are matched the same way as everything else: their "artist" in
# Plex is usually "Various Artists", so album + title is the only reliable key.
compilations = tracks_to_match.count { |track| track['Compilation'] }
puts "# of tracks to sync: #{tracks_to_match.size} (#{compilations} from compilations)\n\n"

puts "Matching tracks (by file path, falling back to album + title)...\n\n"

matched = []   # [apple_music_track, PlexTrack]
unmatched = [] # apple_music_track

tracks_to_match.each do |apple_music_track|
  # Path match is exact (Plex mirrors the Apple files); album+title is a
  # fallback for anything whose location doesn't line up.
  plex_track = PlexTrack.match_by_path(apple_music_track['Location']) ||
               PlexTrack.match(
                 apple_music_track['Name'],
                 apple_music_track['Album'],
                 artist: apple_music_track['Album Artist'] || apple_music_track['Artist'],
                 track_number: apple_music_track['Track Number']
               )

  if plex_track
    matched << [apple_music_track, plex_track]
  else
    unmatched << apple_music_track
  end
end

# For the dry-run reports, surface albums/artists that matched *nothing* — those
# are the ones most likely genuinely absent from Plex (vs. a per-track miss).
matched_albums = matched.map { |apple, _| apple['Album'] }.compact.to_set
matched_artists = matched.map { |apple, _| apple['Album Artist'] || apple['Artist'] }.compact.to_set

missing_albums = unmatched.filter_map { |t| t['Album'] }.uniq.reject { |a| matched_albums.include?(a) }
unmatched_artists = unmatched.filter_map { |t| t['Album Artist'] || t['Artist'] }
missing_artists = unmatched_artists.uniq.reject { |a| matched_artists.include?(a) }

puts "Tracks matched: #{matched.size} out of #{tracks_to_match.size}"
puts "Tracks not found: #{unmatched.size}"
puts "Albums with no matches: #{missing_albums.size}"
puts "Artists with no matches: #{missing_artists.size}"
puts
puts "Time: #{Time.now - start_time} seconds"

if dry_run
  puts "\nWriting reports (missing_tracks.json, missing_albums.json, missing_artists.json)...\n\n"
  write_missing(File.join(ROOT, 'missing_tracks.json'), unmatched.filter_map { |t| t['Name'] })
  write_missing(File.join(ROOT, 'missing_albums.json'), missing_albums)
  write_missing(File.join(ROOT, 'missing_artists.json'), missing_artists)
  exit 0
end

matched.each do |apple_music_track, track|
  play_count = apple_music_track['Play Count']
  last_played_date = apple_music_track['Play Date UTC'] || apple_music_track['Date Modified'] || default_date
  skip_count = apple_music_track['Skip Count']
  last_skipped_date = apple_music_track['Skip Date'] || apple_music_track['Date Modified'] || default_date
  track_rating = apple_music_track['Rating'] / 10 if apple_music_track['Rating']
  album_rating = apple_music_track['Album Rating'] / 10 if apple_music_track['Album Rating']

  puts "Importing details of #{apple_music_track['Artist']} - " \
       "#{apple_music_track['Album']} - #{apple_music_track['Name']}"

  if config['import_plays'] && play_count&.positive?
    puts 'Importing plays to plex database...'
    puts "Play Count: #{play_count}"
    puts "Last Played: #{last_played_date}\n\n"
    play_count.times do
      track.add_listen_at(last_played_date, config['account_id'], config['device_id'])
    end
  end

  if config['import_skips'] && skip_count&.positive?
    puts 'Importing skips to plex database...'
    puts "Skip Count: #{skip_count}"
    puts "Last Skipped: #{last_skipped_date}\n\n"
    skip_count.times do
      track.add_skip_at(last_skipped_date, config['account_id'], config['device_id'])
    end
  end

  if config['import_track_ratings'] && track_rating
    puts 'Importing track rating to plex database...'
    puts "Track Rating: #{track_rating}\n\n"
    track.set_rating(track_rating, config['account_id'])
  end

  next unless config['import_album_ratings'] && album_rating

  puts 'Importing album rating to plex database...'
  puts "Album Rating: #{album_rating}\n\n"
  track.album.set_rating(album_rating, config['account_id'])
end
