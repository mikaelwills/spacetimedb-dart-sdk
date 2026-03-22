#!/bin/bash
# Setup script for SpacetimeDB test environment
# Starts a local in-memory server and publishes the test module

set -e

TEST_SERVER="http://localhost:3000"

echo "Setting up SpacetimeDB test environment..."

if ! command -v spacetime &> /dev/null; then
    echo "Error: spacetime CLI not found"
    echo "Install from https://spacetimedb.com/install"
    exit 1
fi

echo "SpacetimeDB CLI found"

# Check if server is already running on localhost:3000
if curl -s -o /dev/null -w "%{http_code}" "$TEST_SERVER/database" 2>/dev/null | grep -q "^[0-4]"; then
    echo "SpacetimeDB already running at $TEST_SERVER"
else
    echo "Starting SpacetimeDB server (in-memory)..."
    spacetime start --in-memory --listen-addr 0.0.0.0:3000 &
    for i in $(seq 1 15); do
        sleep 1
        if curl -s -o /dev/null "$TEST_SERVER/database" 2>/dev/null; then
            echo "SpacetimeDB server started"
            break
        fi
        if [ "$i" -eq 15 ]; then
            echo "Error: Server failed to start after 15s"
            exit 1
        fi
    done
fi

# Login to local server
echo "Logging into local server..."
spacetime login --server-issued-login "$TEST_SERVER" || true

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
TEST_MODULE_DIR="$SCRIPT_DIR/../spacetime_test_module"

if [ ! -d "$TEST_MODULE_DIR" ]; then
    echo "Error: Test module directory not found at $TEST_MODULE_DIR"
    exit 1
fi

cd "$TEST_MODULE_DIR"

echo "Building test module..."
spacetime build

echo "Publishing test module to $TEST_SERVER..."
spacetime publish --delete-data=always -s "$TEST_SERVER" notesdb || {
    echo "Publish failed - trying delete + republish..."
    spacetime delete notesdb -s "$TEST_SERVER" --yes 2>/dev/null || true
    spacetime publish -s "$TEST_SERVER" notesdb
}

echo "Generating test code from local project..."
cd "$SCRIPT_DIR/.."
dart run spacetimedb_dart_sdk:generate \
    --project-path spacetime_test_module \
    --output test/generated

echo ""
echo "Test environment setup complete!"
echo ""
echo "Run tests with:"
echo "  dart test"
echo ""
