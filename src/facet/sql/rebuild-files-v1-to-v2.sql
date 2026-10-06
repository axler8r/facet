CREATE TABLE files_migrating (
  id INTEGER PRIMARY KEY, path TEXT NOT NULL,
  device INTEGER NOT NULL, inode INTEGER NOT NULL, size INTEGER NOT NULL,
  mtime_ns INTEGER NOT NULL, first_seen INTEGER NOT NULL, last_seen INTEGER NOT NULL,
  state TEXT NOT NULL DEFAULT 'PRESENT', hash_algorithm TEXT, hash_value TEXT,
  hash_time INTEGER, UNIQUE(device, inode));
INSERT INTO files_migrating
  SELECT id, path, device, inode, size, mtime_ns, first_seen, last_seen,
         state, hash_algorithm, hash_value, hash_time FROM files;
DROP TABLE files;
ALTER TABLE files_migrating RENAME TO files;
