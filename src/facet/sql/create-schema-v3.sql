CREATE TABLE files (
  id INTEGER PRIMARY KEY,
  path TEXT NOT NULL,
  device INTEGER NOT NULL,
  inode INTEGER NOT NULL,
  size INTEGER NOT NULL,
  mtime_ns INTEGER NOT NULL,
  first_seen INTEGER NOT NULL,
  last_seen INTEGER NOT NULL,
  state TEXT NOT NULL DEFAULT 'PRESENT',
  hash_algorithm TEXT,
  hash_value TEXT,
  hash_time INTEGER,
  UNIQUE(device, inode)
);

CREATE INDEX idx_files_device_inode ON files(device, inode);
CREATE INDEX idx_files_path ON files(path);
CREATE UNIQUE INDEX idx_files_present_path ON files(path) WHERE state = 'PRESENT';
CREATE INDEX idx_files_state ON files(state);

CREATE TABLE attribute_definitions (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  type TEXT NOT NULL,
  required INTEGER NOT NULL DEFAULT 0,
  description TEXT,
  min_value REAL,
  max_value REAL,
  min_integer INTEGER,
  max_integer INTEGER
);

CREATE TABLE enum_values (
  id INTEGER PRIMARY KEY,
  attribute_id INTEGER NOT NULL REFERENCES attribute_definitions(id) ON DELETE CASCADE,
  value TEXT NOT NULL,
  UNIQUE(attribute_id, value)
);

CREATE TABLE attribute_values (
  file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
  attribute_id INTEGER NOT NULL REFERENCES attribute_definitions(id) ON DELETE CASCADE,
  value_text TEXT,
  value_integer INTEGER,
  value_real REAL,
  value_boolean INTEGER,
  PRIMARY KEY(file_id, attribute_id)
);

CREATE TABLE attribute_history (
  id INTEGER PRIMARY KEY,
  file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
  attribute_id INTEGER NOT NULL REFERENCES attribute_definitions(id) ON DELETE CASCADE,
  old_value TEXT,
  new_value TEXT,
  changed_at INTEGER NOT NULL
);

CREATE INDEX idx_attribute_values_file ON attribute_values(file_id);
CREATE INDEX idx_attribute_values_attr ON attribute_values(attribute_id);
CREATE INDEX idx_history_file ON attribute_history(file_id);
