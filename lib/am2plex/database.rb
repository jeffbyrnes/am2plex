# frozen_string_literal: true

require 'active_record'

module Am2plex
  # Establishes the ActiveRecord connection to a copy of the Plex SQLite
  # database. `bad_attribute_names: :hash` lets us keep Plex's `hash` column
  # (which would otherwise collide with Object#hash) accessible.
  module Database
    module_function

    def connect(path)
      ActiveRecord::Base.establish_connection(
        adapter: 'sqlite3',
        database: path,
        bad_attribute_names: :hash
      )
    end
  end
end
