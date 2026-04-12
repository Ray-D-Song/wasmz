#!/bin/bash
set -e

LIB_DIR="$(cd "$(dirname "$0")/lib" && pwd)"
cd "$LIB_DIR"

# Extract latest SQLite version and year from download page
PAGE=$(curl -sL "https://www.sqlite.org/download.html")

# Format: PRODUCT,3.53.0,2026/sqlite-amalgamation-3530000.zip,...
VERSION_INFO=$(echo "$PAGE" | grep -oE 'PRODUCT,[0-9]+\.[0-9]+\.[0-9]+,[0-9]+/sqlite-amalgamation-[0-9]+\.zip' | head -1)

if [ -z "$VERSION_INFO" ]; then
    echo "Error: Could not find SQLite amalgamation version info"
    exit 1
fi

YEAR=$(echo "$VERSION_INFO" | cut -d',' -f3 | cut -d'/' -f1)
ZIP_NAME=$(echo "$VERSION_INFO" | cut -d',' -f3 | cut -d'/' -f2)

ZIP_URL="https://www.sqlite.org/$YEAR/$ZIP_NAME"

echo "Downloading SQLite amalgamation from: $ZIP_URL"

# Download and extract
curl -sL "$ZIP_URL" -o sqlite-amalgamation.zip
unzip -o sqlite-amalgamation.zip
mv sqlite-amalgamation-*/sqlite3.c .
mv sqlite-amalgamation-*/sqlite3.h .
rm -rf sqlite-amalgamation-* sqlite-amalgamation.zip

echo "SQLite amalgamation downloaded to $LIB_DIR"
echo "sqlite3.c and sqlite3.h are ready"
