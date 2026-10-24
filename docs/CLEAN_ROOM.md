# Independent implementation

YTzoom is implemented as an independent iOS tweak. Its runtime, settings, download manager, media players, networking, UI controllers and build tooling are maintained in this repository.

Private YouTube class and selector names are treated as compatibility facts. Implementations are written against observed YouTube behavior and are guarded so missing classes disable only the affected feature.

See [Asset Provenance](ASSET_PROVENANCE.md) and [Third-Party Notices](../THIRD_PARTY_NOTICES.md).
