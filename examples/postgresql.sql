-- PostgreSQL 19 Beta 4; run in a fresh test session with no open transaction.
-- The IGNORE NULLS example requires 19. No extensions or persistent objects.

/* Both engines support /* nested comments */ in a block. */
SELECT 1 AS nested_comment_ok;

SELECT pg_typeof(1e0) AS scientific_type, -- numeric
       0xFF AS hex_integer,              -- 255 (16+)
       1_000 AS separated_integer,       -- 1000 (16+)
       7 / 2 AS integer_division;        -- 3
SELECT 'NaN'::float8 = 'NaN'::float8 AS float_nan_equal, -- true
       'NaN'::numeric = 'NaN'::numeric AS numeric_nan_equal; -- true
SELECT U&'\0041\0042' AS unicode_text, E'\u0041' AS escape_unicode; -- AB, A

SELECT v FROM (VALUES (1), (NULL)) AS d(v) WHERE v = NULL; -- no rows
SELECT v FROM (VALUES (1), (NULL)) AS d(v) WHERE v IS NULL; -- one NULL

SELECT id, day_no, qty,
       sum(qty) OVER (ORDER BY day_no) AS range_total, -- 30, 30, 35
       sum(qty) OVER w AS rows_total                 -- 10, 30, 35
FROM (VALUES (1, 1, 10), (2, 1, 20), (3, 2, 5)) AS d(id, day_no, qty)
WINDOW w AS (ORDER BY day_no, id ROWS UNBOUNDED PRECEDING)
ORDER BY id;

SELECT id, v,
       last_value(v) IGNORE NULLS OVER (
           ORDER BY id ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
       ) AS carried_forward -- 10, 10, 20
FROM (VALUES (1, 10), (2, NULL), (3, 20)) AS d(id, v)
ORDER BY id;

-- One result row with an empty array, versus one NULL aggregate result.
SELECT json_array(SELECT x FROM (VALUES (1)) AS d(x) WHERE false) AS constructor_empty;
SELECT json_agg(x) AS aggregate_empty FROM (VALUES (1)) AS d(x) WHERE false;
SELECT NULLIF(json_array(SELECT x FROM (VALUES (1)) AS d(x) WHERE false)::jsonb,
              '[]'::jsonb) AS legacy_null;

BEGIN;
CREATE TEMP TABLE sql_reference_ddl (id integer PRIMARY KEY, qty integer CHECK (qty > 0));
INSERT INTO sql_reference_ddl VALUES (1, NULL); -- CHECK allows UNKNOWN
ALTER TABLE sql_reference_ddl ADD COLUMN note text;
CREATE INDEX ix_sql_reference_ddl_qty ON sql_reference_ddl (qty);
TRUNCATE TABLE sql_reference_ddl;
ROLLBACK;
SELECT to_regclass('pg_temp.sql_reference_ddl') AS object_after_rollback; -- NULL
