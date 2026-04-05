# Testing Guide

## Prerequisites

1. **Install SpacetimeDB CLI**
   ```bash
   curl --proto '=https' --tlsv1.2 -sSf https://install.spacetimedb.com | sh
   ```

2. **Verify Installation**
   ```bash
   spacetime --version
   ```

## Quick Start

Just run the tests - setup happens automatically:

```bash
dart test
```

Integration tests auto-setup on first run: start server, build module, publish database, generate code to `test/generated/`.

## Running Tests

```bash
# All tests
dart test

# Unit tests only (no DB needed)
dart test test/unit/ test/codec/ test/messages/ test/auth/

# Integration tests only
dart test test/integration/

# Specific test file
dart test test/integration/crud_test.dart

# Verbose output
dart test -r expanded
```

## Test Structure

**Unit Tests** (no DB required):
- `test/codec/` - BSATN encoding/decoding
- `test/messages/` - Protocol message parsing
- `test/unit/` - Connection config, reducer caller
- `test/auth/` - Identity and authentication

**Integration Tests** (require SpacetimeDB):
- `test/integration/` - Live connection, CRUD, reducers, error handling

**Code Generation Tests**:
- `test/codegen/` - Schema fetching, code generation

## Troubleshooting

| Error | Solution |
|-------|----------|
| Connection refused | Run `spacetime start` |
| Database not found | Run `./tool/setup_test_db.sh` |
| Tests timeout | Integration tests have 60s timeout (see `dart_test.yaml`) |
| Command not found | Install CLI from https://spacetimedb.com/install |

## Clean Up

Tests now tear down the SpacetimeDB server and delete `notesdb` automatically at
the end of each test file via `tearDownAll(cleanupTestEnvironment)`. No manual
cleanup is normally required. If a run is killed mid-execution and leaves a
stale server on port 3000:

```bash
spacetime delete notesdb -y
pkill -f 'spacetimedb-standalone.*3000'
```

## Test Module

Located in `spacetime_test_module/`:
- `Note` table with `NoteStatus` enum (sum type)
- Reducers: `create_note`, `update_note`, `delete_note`, `init`

Code is auto-generated to `test/generated/` when tests run.
