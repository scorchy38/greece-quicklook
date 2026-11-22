# Data fixtures

Every file here is synthetic, written by `make-fixtures.py` (Python 3 with `sqlite3`; the Parquet files also need `pyarrow`). The names, ports, ferry operators and numbers are invented. Run it again to rebuild them:

    python3 -I Fixtures/data/make-fixtures.py

| File | What it exercises |
|---|---|
| `islands.tsv` | Numbers with and without thousands separators, dates with gaps, booleans, empty cells |
| `voyages.psv` | Pipe-separated text, timestamps, decimals, booleans |
| `harbour.sqlite` | Ten tables, foreign keys (one self-referencing, one composite), a WITHOUT ROWID table, a partial index, a view, a trigger, blobs |
| `events.jsonl` | JSON Lines with nested objects, missing keys, nulls and one invalid line |
| `matrix.ndjson` | Lines that are arrays, not objects (shown as code) |
| `ferries.har` | A page load: redirects, scripts, styles, fonts, images with bodies, a JSON API call, a POST, a 404, a 500 and a failed request |
| `lock/<tool>/…` | One lock file per tool (npm v1 and v3, Yarn v1 and Berry, pnpm 9, Bun, Cargo, Bundler, Poetry, uv, Pipenv, CocoaPods, SwiftPM, Composer, Go, Mix, pub, Nix, Gradle, NuGet), with the manifests that say which dependencies are direct |
| `strings/Localizable.xcstrings` | A String Catalog: translated, needs review, new, stale, plural variations, a key that isn't translated |
| `strings/Resources/*.lproj` | Classic `.strings` files (UTF-8 and UTF-16), and a `.stringsdict` |
| `strings/binary/InfoPlist.strings` | A binary property list `.strings` file |
| `dbf/dbase3`, `dbf/dbase4` | dBase III and IV tables with `.dbt` memos and a deleted record |
| `dbf/foxpro` | Visual FoxPro: integer, currency, datetime, double, nullable fields (`_NullFlags`), `.fpt` memos, Greek text in code page 1253 |
| `parquet/*.parquet` | Snappy with dictionaries and three row groups, uncompressed plain, gzip with v2 data pages, and Zstandard (schema only) |

The million-row SQLite database the performance tests need is built in a temporary folder at test time (`SQLiteDataTests.millionRowDatabase`), not committed.
