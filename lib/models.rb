# frozen_string_literal: true

# Aggressive, symmetric text normalization used to compare Apple Music titles
# against Plex titles. Applied to BOTH sides so spelling differences (diacritics,
# apostrophe/dash variants, "&" vs "and", a leading "The", punctuation) stop
# blocking otherwise-identical matches.
module MatchText
  module_function

  EDITION = /[(\[][^)\]]*(?:remaster|deluxe|edition|expanded|anniversary|bonus|mono|stereo|version|reissue)[^)\]]*[)\]]/i

  def normalize(str)
    return '' if str.nil?

    str = str.unicode_normalize(:nfkd)
    str = str.chars.grep_v(/\p{Mn}/).join # strip diacritics
    str = str.downcase
    str = str.gsub(/[’‘'`]/, '').gsub(/[‐\-–—]/, ' ') # drop apostrophes, dashes -> space
    str = str.gsub(/\s*&\s*/, ' and ')                # & -> and
    str = str.gsub(/\bthe\b/, ' ')                    # drop "the"
    str = str.gsub(/[^[:alnum:]\s]/, ' ')             # drop remaining punctuation
    str.gsub(/\s+/, ' ').strip
  end

  # Normalize after stripping "(Deluxe Edition)"/"(Remastered)"-style qualifiers,
  # so an Apple album matches its differently-tagged Plex counterpart.
  def base(str)
    normalize(str.to_s.gsub(EDITION, ''))
  end
end

class PlexMetadataItemSetting < ActiveRecord::Base
  self.table_name = 'metadata_item_settings'
end

class PlexMetadataItemView < ActiveRecord::Base
  self.table_name = 'metadata_item_views'
end

class PlexMetadataItem < ActiveRecord::Base
  self.table_name = 'metadata_items'

  def self.instance_method_already_implemented?(method_name)
    return true if method_name == 'hash'

    super
  end

  CONFIG_DIR = File.expand_path('../config', __dir__)

  def self.load_mapping(filename)
    path = File.join(CONFIG_DIR, filename)
    File.exist?(path) ? JSON.parse(File.read(path)) : {}
  end

  ARTIST_MAPPING = load_mapping('artist_mapping.json')
  ALBUM_MAPPING = load_mapping('album_mapping.json')
  TRACK_MAPPING = load_mapping('track_mapping.json')
end

class PlexArtist < PlexMetadataItem
  has_many :albums, foreign_key: 'parent_id', class_name: 'PlexAlbum'
  default_scope { where(metadata_type: 8) }
end

class PlexAlbum < PlexMetadataItem
  belongs_to :artist, foreign_key: 'parent_id', class_name: 'PlexArtist', inverse_of: :albums
  has_many :tracks, foreign_key: 'parent_id', class_name: 'PlexTrack'
  has_one :metadata_item_setting, primary_key: 'guid', foreign_key: 'guid', class_name: 'PlexMetadataItemSetting'
  default_scope { where(metadata_type: 9) }

  def set_rating(rating, account_id)
    build_metadata_item_setting unless metadata_item_setting
    metadata_item_setting.update(rating: rating, account_id: account_id)
  end
end

class PlexTrack < PlexMetadataItem
  belongs_to :album, foreign_key: 'parent_id', class_name: 'PlexAlbum', inverse_of: :tracks
  has_one :metadata_item_setting, primary_key: 'guid', foreign_key: 'guid', class_name: 'PlexMetadataItemSetting'
  has_many :metadata_item_views, primary_key: 'guid', foreign_key: 'guid', class_name: 'PlexMetadataItemView'
  default_scope { where(metadata_type: 10) }

  # Match an Apple Music track to a Plex track by requiring BOTH the track title
  # AND the album title to agree (after normalization). Artist is deliberately
  # NOT required: Plex files artists very differently (collaborations,
  # compilations, guest features), so an album+title agreement is both more
  # reliable and keeps false positives low. Artist and track number are only
  # used to break ties when several albums collide on the same title.
  def self.match(track_name, album_name, artist: nil, track_number: nil)
    return nil if track_name.to_s.empty? || album_name.to_s.empty?

    track_name = TRACK_MAPPING[track_name] || track_name
    album_name = ALBUM_MAPPING[album_name] || album_name

    candidates = match_index[MatchText.normalize(track_name)]
    candidates = match_index[MatchText.base(track_name)] if candidates.empty?
    return nil if candidates.empty?

    album_norm = MatchText.normalize(album_name)
    album_base = MatchText.base(album_name)
    hits = candidates.select do |c|
      c[:album] == album_norm || (!album_base.empty? && c[:album_base] == album_base)
    end
    return nil if hits.empty?

    find(break_tie(hits, artist, track_number)[:id])
  end

  # Among album+title matches, prefer the candidate whose artist agrees, then
  # one whose track number agrees, falling back to the first. Artist is a hint
  # for disambiguation only, never a match requirement.
  def self.break_tie(hits, artist, track_number)
    return hits.first if hits.one?

    name = artist && (ARTIST_MAPPING[artist] || artist)
    artist_norm = name && MatchText.normalize(name)
    artist_norm = nil if artist_norm == ''
    by_artist = artist_norm ? hits.select { |c| c[:artist] == artist_norm } : []
    by_number = track_number ? hits.select { |c| c[:index] == track_number } : []

    (by_artist & by_number).first || by_artist.first || by_number.first || hits.first
  end

  # Build (and memoize) an in-memory index of every Plex track, keyed by
  # normalized title, so matching 25k Apple tracks stays fast.
  def self.match_index
    @match_index ||= build_match_index
  end

  def self.build_match_index
    artist_titles = PlexArtist.pluck(:id, :title).to_h
    album_info = PlexAlbum.pluck(:id, :title, :parent_id).to_h do |id, title, artist_id|
      [id, [title, artist_titles[artist_id]]]
    end
    index = Hash.new { |hash, key| hash[key] = [] }
    pluck(:id, :title, :parent_id, :index).each do |id, title, album_id, track_index|
      album_title, artist_title = album_info[album_id]
      entry = {
        id: id,
        album: MatchText.normalize(album_title),
        album_base: MatchText.base(album_title),
        artist: MatchText.normalize(artist_title),
        index: track_index
      }
      title_norm = MatchText.normalize(title)
      title_base = MatchText.base(title)
      index[title_norm] << entry
      index[title_base] << entry unless title_base == title_norm
    end
    index
  end

  def set_rating(rating, account_id)
    build_metadata_item_setting unless metadata_item_setting
    metadata_item_setting.update(rating: rating, account_id: account_id)
  end

  def add_listen_at(datetime, account_id, device_id)
    metadata_item_views.create(
      thumb_url: '',
      account_id: account_id,
      guid: guid,
      metadata_type: 10,
      library_section_id: library_section_id,
      grandparent_title: album.artist.title,
      parent_index: album.index,
      parent_title: album.title,
      index: index,
      title: title,
      viewed_at: datetime.to_i,
      grandparent_guid: album.artist.guid,
      device_id: device_id
    )

    build_metadata_item_setting unless metadata_item_setting
    metadata_item_setting.update(
      view_count: (metadata_item_setting.view_count || 0) + 1,
      last_viewed_at: datetime.to_i
    )
  end

  def add_skip_at(datetime, _account_id, _device_id)
    build_metadata_item_setting unless metadata_item_setting
    metadata_item_setting.update(
      skip_count: (metadata_item_setting.skip_count || 0) + 1,
      last_skipped_at: datetime.to_i
    )
  end
end
