# frozen_string_literal: true

require 'cgi'

module Am2plex
  # Aggressive, symmetric text normalization used to compare Apple Music titles
  # against Plex titles. Applied to BOTH sides so spelling differences (diacritics,
  # apostrophe/dash variants, "&" vs "and", a leading "The", punctuation) stop
  # blocking otherwise-identical matches.
  module MatchText
    module_function

    EDITION = /
      [(\[][^)\]]*
      (?:remaster|deluxe|edition|expanded|anniversary|bonus|mono|stereo|version|reissue)
      [^)\]]*[)\]]
    /ix

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

    # Path below the music library root ("Artist/Album/Track.ext"), normalized for
    # comparison. The Plex library is a 1:1 copy of the Apple Music files, so this
    # relative path is identical on both sides once the differing root prefix,
    # URL-encoding, unicode form (macOS NFD vs. Linux NFC) and case are reconciled.
    MUSIC_ROOT = %r{.*/media/music/}i

    def relative_path(path)
      decoded = CGI.unescape(path.to_s.sub(%r{\Afile://}, ''))
      decoded.sub(MUSIC_ROOT, '').unicode_normalize(:nfc).downcase.chomp('/')
    end
  end
end
