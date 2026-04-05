# Contributing

## Setup

```bash
git clone https://github.com/YOUR_USERNAME/spacetimedb_dart_sdk.git
cd spacetimedb_dart_sdk
dart pub get
dart test
```

Requires Dart 3.5.4+ and SpacetimeDB CLI.

## Pull Requests

1. Fork and branch from `main`
2. Run `dart analyze` and `dart format .`
3. Add tests for new functionality
4. Ensure `dart test` passes
5. Submit PR

CI runs the full integration suite against a real SpacetimeDB on every PR — if you only touched pure-Dart code you don't need a local SpacetimeDB install to submit, the CI check will catch any regressions. See `TESTING.md` for details.

## Code Style

- Follow [Effective Dart](https://dart.dev/guides/language/effective-dart)
- **Never use `as` casts** - use type guards (`is`) instead
- Run `dart analyze` before committing

## Bug Reports

Include: Dart version, SpacetimeDB version, OS, steps to reproduce, expected vs actual behavior.

## License

Contributions are licensed under Apache 2.0.
