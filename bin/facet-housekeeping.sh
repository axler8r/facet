#!/bin/sh
set -eu

usage() {
    printf 'Usage: %s [--remove-missing|-r] [--] [CATALOGUE.db]\n' "$0" >&2
    exit 1
}

remove_missing=0
database=.facet/catalogue.db
database_set=0
while [ "$#" -gt 0 ]; do
    case $1 in
        --remove-missing|-r) remove_missing=1 ;;
        --) shift; break ;;
        -*) usage ;;
        *)
            [ "$database_set" -eq 0 ] || usage
            database=$1
            database_set=1
            ;;
    esac
    shift
done
for argument in "$@"; do
    [ "$database_set" -eq 0 ] || usage
    database=$argument
    database_set=1
done

if ! command -v sqlite3 >/dev/null 2>&1; then
    printf 'Error: sqlite3 is required.\n' >&2
    exit 1
fi

if [ ! -f "$database" ]; then
    printf 'Error: catalogue not found: %s\n' "$database" >&2
    exit 1
fi
case $database in
    /*) ;;
    *) database=$PWD/$database ;;
esac

backup_dir=$(mktemp -d "${database}.backup.XXXXXX")
if ! (cd "$backup_dir" && sqlite3 -batch -bail -readonly "$database" ".timeout 5000" ".backup catalogue.db"); then
    printf 'Error: backup failed; catalogue was not changed.\n' >&2
    exit 1
fi
printf 'Backup: %s/catalogue.db\n' "$backup_dir"

sqlite3 -batch -bail "$database" <<SQL
.timeout 5000
PRAGMA foreign_keys = ON;
BEGIN IMMEDIATE;

CREATE TEMP TABLE housekeeping_options AS SELECT $remove_missing AS remove_missing;
CREATE TEMP TABLE housekeeping_check (valid INTEGER NOT NULL CHECK (valid = 1));
INSERT INTO housekeeping_check
SELECT user_version IN (1, 2, 3) FROM pragma_user_version;
INSERT INTO housekeeping_check
SELECT integrity_check = 'ok' FROM pragma_integrity_check;
INSERT INTO housekeeping_check
SELECT NOT EXISTS (SELECT 1 FROM pragma_foreign_key_check);

CREATE TEMP TABLE housekeeping_duplicates AS
SELECT id FROM (
    SELECT id, ROW_NUMBER() OVER (
        PARTITION BY path
        ORDER BY (state = 'PRESENT') DESC, last_seen DESC, id DESC
    ) AS position
    FROM files
) WHERE position > 1;

DELETE FROM files WHERE id IN (SELECT id FROM housekeeping_duplicates);

CREATE TEMP TABLE housekeeping_missing AS
SELECT id FROM files
WHERE state = 'MISSING' AND (SELECT remove_missing FROM housekeeping_options) = 1;
DELETE FROM files WHERE id IN (SELECT id FROM housekeeping_missing);

INSERT INTO housekeeping_check
SELECT NOT EXISTS (SELECT 1 FROM files GROUP BY path HAVING COUNT(*) > 1);
INSERT INTO housekeeping_check
SELECT remove_missing = 0 OR NOT EXISTS (SELECT 1 FROM files WHERE state = 'MISSING')
FROM housekeeping_options;
INSERT INTO housekeeping_check
SELECT integrity_check = 'ok' FROM pragma_integrity_check;
INSERT INTO housekeeping_check
SELECT NOT EXISTS (SELECT 1 FROM pragma_foreign_key_check);

COMMIT;
SELECT 'Removed duplicate file rows: ' || COUNT(*) FROM housekeeping_duplicates;
SELECT 'Removed missing file rows: ' || COUNT(*) FROM housekeeping_missing
HAVING (SELECT remove_missing FROM housekeeping_options) = 1;
SQL
