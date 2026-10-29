# MMDB reader fixture

`GeoIP2-City-Test.mmdb` is the small synthetic test database from [MaxMind-DB test-data](https://github.com/maxmind/MaxMind-DB/blob/main/test-data/GeoIP2-City-Test.mmdb), retrieved 2026-10-29. It is test data, not a production geolocation database. Upstream provides MIT or Apache 2.0 licensing; the MIT license is retained in `MaxMind-LICENSE-MIT`.

Expected country/subdivision values were checked against upstream [source-data/GeoIP2-City-Test.json](https://github.com/maxmind/MaxMind-DB/blob/main/source-data/GeoIP2-City-Test.json). This fixture is only used by tests and is not bundled in the app. Other malformed and layout fixtures are generated in GeoTests.swift.
