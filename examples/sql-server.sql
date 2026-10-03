-- SQL Server 2025 (17.x), compatibility >= 160 for WINDOW.
-- Self-contained examples; use a fresh test connection with no open transaction.
-- No PREVIEW_FEATURES required. Temporary DDL is rolled back.
SET NOCOUNT ON;
SET XACT_ABORT ON;

/* Both engines support /* nested comments */ in a block. */
SELECT 1 AS nested_comment_ok;

SELECT SQL_VARIANT_PROPERTY(1e0, 'BaseType') AS scientific_type, -- float
       7 / 2 AS integer_division;                              -- 3
SELECT UNISTR(N'\0041\0042') AS unicode_text;                   -- AB

-- WHERE accepts TRUE; UNKNOWN from NULL comparison is filtered out.
SELECT v FROM (VALUES (1), (NULL)) AS d(v) WHERE v = NULL; -- no rows
SELECT v FROM (VALUES (1), (NULL)) AS d(v) WHERE v IS NULL; -- one NULL

-- ORDER BY is required even when STRING_SPLIT exposes ordinal.
SELECT value, ordinal FROM STRING_SPLIT(N'b,a,c', N',', 1) ORDER BY ordinal;

-- RANGE includes all peers; ROWS with a unique tie-breaker advances per row.
SELECT id, day_no, qty,
       SUM(qty) OVER (ORDER BY day_no) AS range_total, -- 30, 30, 35
       SUM(qty) OVER w AS rows_total                 -- 10, 30, 35
FROM (VALUES (1, 1, 10), (2, 1, 20), (3, 2, 5)) AS d(id, day_no, qty)
WINDOW w AS (ORDER BY day_no, id ROWS UNBOUNDED PRECEDING)
ORDER BY id;

SELECT id, v,
       LAST_VALUE(v) IGNORE NULLS OVER (
           ORDER BY id ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
       ) AS carried_forward -- 10, 10, 20
FROM (VALUES (1, 10), (2, NULL), (3, 20)) AS d(id, v)
ORDER BY id;

-- Native JSON accepts an object/array; JSON_CONTAINS takes a SQL search value.
DECLARE @doc json = N'{"status":"open","items":[1,2]}';
SELECT JSON_CONTAINS(@doc, N'open', '$.status') AS has_status; -- 1
SELECT id FROM (VALUES (1)) AS d(id) WHERE 1 = 0 FOR JSON PATH; -- []

-- CREATE TABLE, ALTER TABLE, CREATE INDEX and TRUNCATE are transactional.
BEGIN TRY
    BEGIN TRAN;
    CREATE TABLE #sql_reference_ddl (id int PRIMARY KEY, qty int NULL CHECK (qty > 0));
    INSERT INTO #sql_reference_ddl VALUES (1, NULL); -- CHECK allows UNKNOWN
    ALTER TABLE #sql_reference_ddl ADD note nvarchar(20) NULL;
    CREATE INDEX ix_sql_reference_ddl_qty ON #sql_reference_ddl (qty);
    TRUNCATE TABLE #sql_reference_ddl;
    ROLLBACK TRAN;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRAN;
    THROW;
END CATCH;
SELECT OBJECT_ID(N'tempdb..#sql_reference_ddl') AS object_after_rollback; -- NULL
