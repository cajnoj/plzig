-- Benchmark data.  Run by bench/driver.py with psql variables:
--   big_rows words csv_rows blob_kb
-- Everything is deterministic (no random()), so every language sees the
-- same rows in the same physical order.
\set ON_ERROR_STOP 1

CREATE EXTENSION plzig;
CREATE EXTENSION plpython3u;
CREATE EXTENSION plperl;
CREATE EXTENSION fuzzystrmatch;   -- the SQL reference of task 6 only

-- tasks 1 and 8
CREATE TABLE bench_big (id int PRIMARY KEY, k int NOT NULL, v int NOT NULL);
INSERT INTO bench_big
SELECT i, (i::bigint * 7919 % 1000)::int, (i::bigint * 31 % 10007)::int
FROM generate_series(1, :big_rows) AS i;

-- task 7: always 100000 keys (the functions compute k = i * 7919 % 100000 + 1)
CREATE TABLE bench_kv (k int PRIMARY KEY, v int NOT NULL);
INSERT INTO bench_kv SELECT i, i % 1000 FROM generate_series(1, 100000) AS i;

-- task 6: pseudo-words of 4..11 lower-case letters
CREATE TABLE bench_words (id int PRIMARY KEY, w text NOT NULL);
INSERT INTO bench_words
SELECT i, translate(substr(md5(i::text), 1, 4 + i % 8), '0123456789', 'gostrqlpez')
FROM generate_series(1, :words) AS i;

-- task 4: CSV lines of 20 fields, valid and invalid identifiers mixed
CREATE TABLE bench_csv (id int PRIMARY KEY, line text NOT NULL);
INSERT INTO bench_csv
SELECT i, string_agg(
    CASE (i + j) % 6
        WHEN 0 THEN '  ' || upper(substr(h, 1, 10)) || ' '
        WHEN 1 THEN 'col_' || substr(h, 1, 8)
        WHEN 2 THEN substr(h, 3, 12)
        WHEN 3 THEN 'Some-Name' || j
        WHEN 4 THEN 'x' || repeat(substr(h, 1, 8), 8)
        ELSE ' _Mixed_Case' || j || '  '
    END, ',' ORDER BY j)
FROM generate_series(1, :csv_rows) AS i,
     generate_series(1, 20) AS j,
     LATERAL (SELECT md5((i * 31 + j)::text) AS h) AS x
GROUP BY i;

-- tasks 5 and 10: one incompressible bytea and one text (ASCII and
-- two-byte UTF-8 characters) of blob_kb kilobytes each
CREATE TABLE bench_blob (id int PRIMARY KEY, b bytea NOT NULL, t text NOT NULL);
INSERT INTO bench_blob
SELECT 1,
       (SELECT string_agg(sha256(int4send(i)), ''::bytea ORDER BY i)
        FROM generate_series(1, :blob_kb * 32) AS i),
       -- 29 characters, 32 bytes in UTF-8
       repeat('Grüße aus Zürich, 0123456789 ', :blob_kb * 32);

-- task 9
CREATE TABLE bench_t9 (id int PRIMARY KEY, v int NOT NULL) WITH (autovacuum_enabled = off);

VACUUM ANALYZE;
