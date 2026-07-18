# am2plex — Apple Music → Plex

`am2plex` imports your listening history from Apple Music into Plex, so you can
move to Plexamp and off the streaming services.

It imports:

- track play counts + last-played date
- track skip counts + last-skipped date
- track ratings
- album ratings

You control which tracks are considered by setting a minimum play count and skip
count. The tool errs on the side of avoiding false positives — it may not import
_everything_, but it works hard not to attach your history to the wrong track.

## How it works

1. Export your Apple Music library to an XML file.
2. Copy your Plex SQLite database somewhere safe to work against.
3. Point a `config.yml` at both files and run a **dry run** to see how well it matches.
4. (Optional) Adjust matches with mapping files, based on the dry-run reports.
5. Run it for real to import the data into your copy of the Plex DB.
6. Move the updated database back into place.

## Installation

`am2plex` is a Ruby gem that installs an `am2plex` executable onto your `$PATH`.

You need SQLite and a Ruby (>= 3.2):

    brew install sqlite3

Then build and install the gem from a checkout of this repo:

    gem build am2plex.gemspec
    gem install ./am2plex-*.gem

That puts `am2plex` on your `$PATH`. Verify with:

    am2plex --version

> **Working on the gem itself?** Use Bundler instead of installing:
> `bundle install`, then run `bundle exec exe/am2plex ...`.

## Usage

    am2plex [options]

    -c, --config PATH   Path to the config file (default: config.yml)
    -n, --dry-run       Preview matches and write reports without touching the Plex DB
    -v, --version       Print version and exit
    -h, --help          Print this help and exit

`am2plex` reads everything it needs from a single config file. By default it
looks for `config.yml` in the current directory; use `--config` to point
elsewhere. A good workflow is to keep the config, your library export, and your
Plex DB copy together in one directory and run `am2plex` from there.

## Configuration

The config is a YAML file. All paths in it are resolved **relative to the config
file's own location** (absolute paths work too), so you can keep everything in
one directory and run from there. See
[`config/config.yml`](config/config.yml) for a complete example.

| key | type | info |
| --- | --- | --- |
| `library` | path | Your exported Apple Music library XML |
| `database` | path | A copy of your Plex SQLite database |
| `artist_mapping` | path | Optional manual artist name mappings (see below) |
| `album_mapping` | path | Optional manual album name mappings |
| `track_mapping` | path | Optional manual track name mappings |
| `minimum_plays` | int | Minimum number of plays for a track to be considered for import |
| `minimum_skips` | int | Minimum number of skips for a track to be considered for import |
| `default_date` | date | `yyyy-mm-dd` used when a play/skip has no timestamp in the Apple Music export |
| `account_id` | int | Your Plex account ID (plays/skips are attributed to it) |
| `device_id` | int | The Plex device ID to attribute plays/skips to |
| `import_plays` | bool | Import track play counts |
| `import_skips` | bool | Import track skip counts |
| `import_track_ratings` | bool | Import track ratings |
| `import_album_ratings` | bool | Import album ratings |

`minimum_plays` and `minimum_skips` are the big dials: they decide whether you
have a ton of matched songs (and mapping work) or only a little. **Run a few dry
runs with different values before doing any manual mapping.**

### Finding your account & device IDs

Run a dry run (below) and it prints the account and device IDs found on your
server.

- **Account ID** — if there's only one, use it. If there are several, the
  lowest-numbered one is usually your own (the server owner's) account.
- **Device ID** — pick any; it doesn't really matter which device your imported
  plays are attributed to.

## Preparing your data

### Export your Apple Music library

1. Open the Music app and go to **File → Library → Export Library…**
2. Save the XML somewhere and point `library:` in your config at it.

### Copy your Plex database

Always work against a **copy** — never the live database.

1. Export a Plex database backup at **Plex → Settings → Troubleshooting**.
2. Point `database:` in your config at the copy.

## Do a dry run

    am2plex --config config/config.yml --dry-run

A dry run modifies nothing. It reports how many tracks were read, filtered,
matched, and missed, and writes three report files into the current directory:

- `missing_tracks.json`
- `missing_albums.json`
- `missing_artists.json`

### Improving matches with mapping files

The three `missing_*.json` reports double as templates for **mapping files**, which
override how an Apple Music name is looked up in Plex. To use them, copy a report
next to your config and rename it:

- `missing_artists.json` → `artist_mapping.json`
- `missing_albums.json` → `album_mapping.json`
- `missing_tracks.json` → `track_mapping.json`

Then reference them from your config (`artist_mapping:`, `album_mapping:`,
`track_mapping:`) and edit the **values** to match what's in your Plex library.
Each entry is `"Apple Music name": "Plex name"`. For example, if Apple has the
artist `Jay Z` but Plex has `JAY-Z`:

    { "Jay Z": "JAY-Z" }

On the next run, that mapping is used to find the artist/album/track in Plex.

**Tip:** fix artists first — it does the most to unlock track matches — then
albums. Common causes of a miss:

- smart quotes and em dashes (we try to fix these, but not always successfully)
- a missing `The`
- `…` vs `...`
- a `- EP`, `- Single`, or `(Deluxe Edition)` suffix on the album/track name

You'll also see genuinely missing artists and albums — modern music you
streamed but never added to your local library.

## Do it for real

Once you're happy with the match count:

1. **Stop Plex Server** — this is critical.
2. Locate the live Plex database, make a backup copy, and **never touch that backup**.
3. Copy the live database to your working directory and point `database:` at it.
4. Run the import (no `--dry-run`); confirm the prompt:

        am2plex --config config/config.yml

5. Rename the updated copy back to `com.plexapp.plugins.library.db` and move it
   back where it came from (mind file permissions).
6. Start Plex Server back up.

## Enjoy

That should be it. A million problems may still arise, but this does its best.
