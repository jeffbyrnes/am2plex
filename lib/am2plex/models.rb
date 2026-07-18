# frozen_string_literal: true

require 'active_record'

module Am2plex
  # Per-account state for a metadata item: rating, view/skip counts, timestamps.
  class PlexMetadataItemSetting < ActiveRecord::Base
    self.table_name = 'metadata_item_settings'
  end

  # A single recorded play of a metadata item (one row per listen).
  class PlexMetadataItemView < ActiveRecord::Base
    self.table_name = 'metadata_item_views'
  end

  # Base model for Plex's metadata_items table, which holds artists, albums and
  # tracks alike, discriminated by metadata_type. Optional manual name-mapping
  # tables (Apple name -> Plex name) are injected at runtime from the config and
  # inherited by every subclass via class_attribute.
  class PlexMetadataItem < ActiveRecord::Base
    self.table_name = 'metadata_items'

    class_attribute :artist_mapping, default: {}
    class_attribute :album_mapping, default: {}
    class_attribute :track_mapping, default: {}

    def self.instance_method_already_implemented?(method_name)
      return true if method_name == 'hash'

      super
    end
  end

  # An artist row (metadata_type 8).
  class PlexArtist < PlexMetadataItem
    has_many :albums, foreign_key: 'parent_id', class_name: 'Am2plex::PlexAlbum'
    default_scope { where(metadata_type: 8) }
  end

  # An album row (metadata_type 9).
  class PlexAlbum < PlexMetadataItem
    belongs_to :artist, foreign_key: 'parent_id', class_name: 'Am2plex::PlexArtist', inverse_of: :albums
    has_many :tracks, foreign_key: 'parent_id', class_name: 'Am2plex::PlexTrack'
    has_one :metadata_item_setting, primary_key: 'guid', foreign_key: 'guid',
                                    class_name: 'Am2plex::PlexMetadataItemSetting'
    default_scope { where(metadata_type: 9) }

    def set_rating(rating, account_id)
      build_metadata_item_setting unless metadata_item_setting
      metadata_item_setting.update(rating: rating, account_id: account_id)
    end
  end

  # A track row (metadata_type 10). Owns the matching logic that pairs an Apple
  # Music track with its Plex counterpart, and the writers that import plays,
  # skips and ratings.
  class PlexTrack < PlexMetadataItem
    belongs_to :album, foreign_key: 'parent_id', class_name: 'Am2plex::PlexAlbum', inverse_of: :tracks
    has_one :metadata_item_setting, primary_key: 'guid', foreign_key: 'guid',
                                    class_name: 'Am2plex::PlexMetadataItemSetting'
    has_many :metadata_item_views, primary_key: 'guid', foreign_key: 'guid',
                                   class_name: 'Am2plex::PlexMetadataItemView'
    default_scope { where(metadata_type: 10) }

    # Preferred matcher: since Plex is a 1:1 copy of the Apple Music files, an
    # Apple track's file location resolves to exactly one Plex track by relative
    # path. This is both more complete and more precise than title matching (it
    # can never confuse two different recordings that share a title).
    def self.match_by_path(location)
      key = MatchText.relative_path(location)
      return nil if key.empty?

      id = path_index[key]
      id && find(id)
    end

    # Memoized index of every Plex track's relative file path -> track id.
    def self.path_index
      @path_index ||= begin
        sql = <<~SQL
          SELECT t.id AS id, mp.file AS file
          FROM metadata_items t
          JOIN media_items mi ON mi.metadata_item_id = t.id
          JOIN media_parts mp ON mp.media_item_id = mi.id
          WHERE t.metadata_type = 10 AND mp.file IS NOT NULL
        SQL
        connection.exec_query(sql).to_h do |row|
          [MatchText.relative_path(row['file']), row['id']]
        end
      end
    end

    # Match an Apple Music track to a Plex track by requiring BOTH the track title
    # AND the album title to agree (after normalization). Artist is deliberately
    # NOT required: Plex files artists very differently (collaborations,
    # compilations, guest features), so an album+title agreement is both more
    # reliable and keeps false positives low. Artist and track number are only
    # used to break ties when several albums collide on the same title.
    def self.match(track_name, album_name, artist: nil, track_number: nil)
      return nil if track_name.to_s.empty? || album_name.to_s.empty?

      track_name = track_mapping[track_name] || track_name
      album_name = album_mapping[album_name] || album_name

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

      name = artist && (artist_mapping[artist] || artist)
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
end
