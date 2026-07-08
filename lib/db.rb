# frozen_string_literal: true

require "active_record"

ActiveRecord::Base.establish_connection(
  adapter: "sqlite3",
  database: File.expand_path("../config/plexdb.sqlite", __dir__),
  bad_attribute_names: :hash
)
