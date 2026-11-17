# Changelog

See [versioning and release preparation](docs/releasing.md) for release gates.

## Unreleased

- Prepared an experimental source preview for Windows 11 x64 and classic
  AirPlay 1/RAOP receivers.
- Retained the Microsoft Public License for the Microsoft-derived driver.
  Original code outside the driver component uses AGPL-3.0-only. Third-party
  components retain their licenses and notices.
- Configured CI to build, test and validate package output on the runner.
  The source preview provides no automated signing, binary uploads or releases.
