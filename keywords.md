# Từ khóa (Keywords)

> **Baseline:** SQL Server **2025** · PostgreSQL **19**.  
> Reserved word ≠ keyword. Unquoted identifier trùng reserved → lỗi parse. Danh sách **không** giống nhau giữa hai engine.

Từ khóa SQL là tín hiệu cho parser, không phải API gọi được. File này **không** liệt kê hết reserved word (xem catalog / Learn). Mỗi nhóm quan trọng: mục đích → ví dụ hai dialect → ghi chú / version. Identifier hay đụng: §20. Quy ước quote: [dialects.md](dialects.md).

PostgreSQL 19 **beta** (GA mục tiêu cuối 10/2026): `GRAPH_TABLE`, `REPACK`, `WAIT FOR`, `FOR PORTION OF`, `ON CONFLICT DO SELECT`, `GROUP BY ALL`, `IGNORE NULLS` window — đối chiếu release notes trước production. SQL Server 2025: `VECTOR`, `CURRENT_DATE`, `JSON_OBJECTAGG` — một phần **PREVIEW**.

---

## Mục lục

- [1. Quy tắc \& triết lý](#1-quy-tắc--triết-lý)
- [2. `SELECT`](#2-select)
- [3. `WITH` (CTE)](#3-with-cte)
- [4. `JOIN` / `LATERAL` / `APPLY`](#4-join--lateral--apply)
- [5. `MERGE`](#5-merge)
- [6. `INSERT` / `UPDATE` / `DELETE` / `TRUNCATE`](#6-insert--update--delete--truncate)
- [7. `RETURNING` / `OUTPUT`](#7-returning--output)
- [8. `TOP` / `LIMIT` / `FETCH`](#8-top--limit--fetch)
- [9. `GRAPH_TABLE` / `MATCH` (PostgreSQL 19)](#9-graph_table--match-postgresql-19)
- [10. `REPACK` (PostgreSQL 19)](#10-repack-postgresql-19)
- [11. `FOR PORTION OF` (PostgreSQL 19)](#11-for-portion-of-postgresql-19)
- [12. `BEGIN` / giao dịch / `WAIT FOR`](#12-begin--giao-dịch--wait-for)
- [13. DDL: `CREATE` / `ALTER` / `DROP`](#13-ddl-create--alter--drop)
- [14. Constraint](#14-constraint)
- [15. Window: `OVER` / `FILTER` / `IGNORE NULLS`](#15-window-over--filter--ignore-nulls)
- [16. `GROUP BY ALL`](#16-group-by-all)
- [17. Điều khiển luồng](#17-điều-khiển-luồng)
- [18. `GRANT` / `REVOKE` / `DENY`](#18-grant--revoke--deny)
- [19. SQL Server 2025 — built-in mới](#19-sql-server-2025--built-in-mới)
- [20. PostgreSQL 19 — clause mới](#20-postgresql-19--clause-mới)
- [21. Hay đụng identifier](#21-hay-đụng-identifier)
- [22. Hai session — ví dụ làm việc](#22-hai-session--ví-dụ-làm-việc)
- [23. Best practices \& checklist](#23-best-practices--checklist)
- [24. Bẫy khi review](#24-bẫy-khi-review)
- [25. Version gates](#25-version-gates)
- [Phụ lục A. Keyword vs hàm vs kiểu](#phụ-lục-a-keyword-vs-hàm-vs-kiểu--cùng-chữ)
- [Phụ lục B. `ON CONFLICT DO SELECT`](#phụ-lục-b-on-conflict-do-select--keyword-path)
- [Phụ lục C. SQL Graph vs SQL/PGQ](#phụ-lục-c-sql-graph-ss-vs-sqlpgq--keyword-đừng-trộn)
- [Phụ lục D. `REPACK` vs `VACUUM` vs `CLUSTER`](#phụ-lục-d-repack-vs-vacuum-vs-cluster--token)

---

## 1. Quy tắc & triết lý

- **Reserved:** không dùng làm identifier trừ khi quote (`"order"`, `[order]`).
- **Unreserved / contextual:** keyword chỉ ở vị trí nhất định (`name`, `value`, `type` trên PostgreSQL; `VALUE` trong `JSON_OBJECTAGG`).
- Danh sách lệch: `USER`, `OFFSET`, `WINDOW`, `FILTER`, `OUTPUT`, `APPLY`, `TOP`, `LIMIT`, `VECTOR`, `REPACK`, `MATCH`.
- Tra cứu: PostgreSQL `SELECT * FROM pg_get_keywords();` (`reserved` / `unreserved`). SQL Server: *Reserved Keywords (Transact-SQL)* trên Learn — không có view đầy đủ tương đương.

```sql
SELECT * FROM "order";
SELECT * FROM [order];                   -- SQL Server
```

Quote cả đời vì tên `user` “chạy được” hôm nay — schema dump, ORM, graph query dễ gãy. Đổi tên (`app_user`) tốt hơn quote.

**Ghi chú:** Keyword mới 19/2025 thường *contextual*: `VECTOR` là kiểu/hàm SS; cột `vector` unquoted có thể parse lệch. `CURRENT_DATE` 2025 biến cột cùng tên thành hàm trong `SELECT current_date`. `GRAPH_TABLE` / `REPACK` không xuất hiện T-SQL.

---

## 2. `SELECT`

- **Loại:** reserved (cả hai)
- **Mục đích:** Chiếu cột từ nguồn; không phải “bắt đầu query” duy nhất (`TABLE`, `VALUES`, `WITH` đứng trước). Logical processing ≠ thứ tự viết — [select.md](select.md).

```sql
-- Cả hai
SELECT id, total * 1.1 AS with_tax
FROM orders
WHERE status = 'paid'
ORDER BY total DESC;

-- PostgreSQL: TABLE t ≡ SELECT * FROM t
TABLE orders LIMIT 5;
```

**Ghi chú:**

- `SELECT` không `ORDER BY` → thứ tự không xác định. `DISTINCT` + `ORDER BY` cột không nằm trong list: SQL Server chặt; PG cho phép trong một số case — đừng dựa.
- `SELECT @v = col FROM t` T-SQL gán biến (không xác định nếu nhiều hàng) — khác `SELECT` trả result set.
- Alias `SELECT` không dùng trong `WHERE` cùng mức.
- `ON CONFLICT DO SELECT` **không** bắt đầu bằng `SELECT` — clause của `INSERT` (§20, [dml.md](dml.md)).
- `SELECT` trong `GRAPH_TABLE ( … COLUMNS (…))` là query ngoài; `COLUMNS` không phải list `SELECT` đầy đủ.

---

## 3. `WITH` (CTE)

- **Mục đích:** Đặt tên subquery; `RECURSIVE` duyệt đồ thị/cây. Trên T-SQL, `WITH` còn là table hint (`WITH (NOLOCK)`) và XML — **không** cùng ngữ nghĩa.

```sql
; WITH cte AS (
    SELECT id FROM orders WHERE status = 'open'
)
SELECT * FROM cte;

WITH RECURSIVE walk AS (
    SELECT id, parent_id FROM nodes WHERE parent_id IS NULL
    UNION ALL
    SELECT n.id, n.parent_id FROM nodes n JOIN walk w ON n.parent_id = w.id
)
SELECT * FROM walk;
```

**Ghi chú:**

- `;` trước `WITH` trên T-SQL nếu statement trước thiếu terminator — [dialects.md](dialects.md).
- Hint `FROM dbo.T WITH (UPDLOCK)` không phải CTE.
- `WITH` XML (`FOR XML`) / `WITH` JSON (`FOR JSON`) SQL Server — [json.md](json.md).
- CTE không phải temp table: tối ưu có thể inline; `MATERIALIZED` / `NOT MATERIALIZED` PostgreSQL (12+) gợi ý.
- SQL/PGQ 19 **chưa** variable-length path — recursive CTE vẫn cần cho đồ thị sâu. `GRAPH_TABLE` không thay `WITH RECURSIVE`.

Chi tiết: [cte-subqueries.md](cte-subqueries.md).

---

## 4. `JOIN` / `LATERAL` / `APPLY`

- **Mục đích:** Kết nguồn. `JOIN` không từ = `INNER`. `APPLY` (SQL Server) ≈ `LATERAL` (PostgreSQL): phía phải phụ thuộc hàng trái.

```sql
SELECT o.id, c.name
FROM orders AS o
INNER JOIN customers AS c ON c.id = o.customer_id;

-- SQL Server
SELECT o.id, p.Price
FROM dbo.Orders AS o
CROSS APPLY dbo.fn_BestPrice(o.Sku) AS p;

-- PostgreSQL
SELECT o.id, p.price
FROM orders AS o
CROSS JOIN LATERAL fn_best_price(o.sku) AS p;
-- hoặc
LEFT JOIN LATERAL fn_best_price(o.sku) AS p ON true;
```

**Ghi chú:**

- `OUTER APPLY` ≡ `LEFT JOIN LATERAL … ON true`.
- `NATURAL JOIN` / `USING`: PG có; SQL Server không `NATURAL` — tránh `NATURAL` (schema evolution).
- `ON` vs `WHERE` với `LEFT JOIN`: predicate phải `ON` nếu muốn giữ hàng không khớp — [joins.md](joins.md).
- PG 19: nhiều `LEFT JOIN` có thể rewrite ANTI; `NOT IN` không NULL → ANTI — [operators.md](operators.md).
- `MATCH` trong `GRAPH_TABLE` rewrite thành join — không keyword `JOIN` trong pattern, nhưng plan = join.

---

## 5. `MERGE`

- **Mục đích:** Một statement khớp nguồn-đích: insert / update / delete theo `WHEN`. Cả hai engine có; **ngữ nghĩa lệch** (SQL Server historically có bug; PG `MERGE` từ 15, không thay hết `ON CONFLICT`).

```sql
-- SQL Server
MERGE dbo.Stock AS t
USING dbo.Staging AS s
ON t.Sku = s.Sku
WHEN MATCHED THEN
    UPDATE SET t.Qty = s.Qty
WHEN NOT MATCHED THEN
    INSERT (Sku, Qty) VALUES (s.Sku, s.Qty)
WHEN NOT MATCHED BY SOURCE THEN
    DELETE
OUTPUT inserted.Sku, $action;

-- PostgreSQL 15+
MERGE INTO stock AS t
USING staging AS s
ON t.sku = s.sku
WHEN MATCHED THEN
    UPDATE SET qty = s.qty
WHEN NOT MATCHED THEN
    INSERT (sku, qty) VALUES (s.sku, s.qty);
```

**Ghi chú:**

- Upsert một hàng PG thường `INSERT … ON CONFLICT` rõ hơn `MERGE`. PG 19: `ON CONFLICT DO SELECT` — §20, [dml.md](dml.md).
- SQL Server `MERGE` cần `;` kết thúc. Race: vẫn cần khóa / `HOLDLOCK` cho invariant — [transactions.md](transactions.md).
- `WHEN NOT MATCHED BY SOURCE` chủ yếu T-SQL.
- `MATCHED` trong `MERGE` ≠ `MATCH` SQL/PGQ.

---

## 6. `INSERT` / `UPDATE` / `DELETE` / `TRUNCATE`

```sql
INSERT INTO orders (customer_id, total) VALUES (1, 99.50);
INSERT INTO orders (customer_id, total) SELECT id, 0 FROM customers;

-- SQL Server UPDATE…FROM
UPDATE o SET o.total = o.total * 1.1
FROM dbo.Orders AS o
JOIN dbo.Customers AS c ON c.Id = o.CustomerId;

-- PostgreSQL UPDATE…FROM (fan-out không xác định nếu nhiều hàng khớp)
UPDATE orders o
SET total = total * 1.1
FROM customers c
WHERE c.id = o.customer_id;

DELETE FROM orders WHERE id = 1;
TRUNCATE TABLE orders;                   -- DDL-ish: PG transactional; SQL Server deallocated pages, quyền khác DELETE
```

**Ghi chú:** `TRUNCATE` SQL Server không fire DELETE trigger (mặc định), reset IDENTITY; PG `TRUNCATE … CASCADE` FK. Không port mù. Chi tiết [dml.md](dml.md).

`UPDATE`/`DELETE … FOR PORTION OF` 19: cùng verb, thêm clause temporal — §11. Không `TRUNCATE FOR PORTION OF`.

`INSERT … ON CONFLICT DO SELECT` 19: keyword `DO` + `SELECT` sau conflict — không phải statement `SELECT` độc lập.

---

## 7. `RETURNING` / `OUTPUT`

Cùng ý: trả hàng ảnh hưởng. **Không** copy tên clause.

```sql
-- PostgreSQL
INSERT INTO orders (customer_id, total) VALUES (1, 10)
RETURNING id, created_at;

UPDATE orders SET total = total + 1 WHERE id = 1
RETURNING *;

-- SQL Server
INSERT INTO dbo.Orders (CustomerId, Total)
OUTPUT inserted.Id, inserted.CreatedAt
VALUES (1, 10);

DELETE FROM dbo.Orders
OUTPUT deleted.Id
WHERE Id = 1;
```

**Ghi chú:**

- `OUTPUT` T-SQL vào table: `OUTPUT … INTO @t`. Trigger + `OUTPUT` ngữ nghĩa phức tạp (hàng `inserted` vs trigger).
- `RETURNING` PG thấy hàng **sau** BEFORE trigger, trước AFTER — đọc docs khi trigger sửa cột.
- `OUTPUT` không dùng được mọi hint/scenario (view, trigger) giống `RETURNING`.
- `DO SELECT … RETURNING` 19: trả hàng **đã có** (conflict), không hàng mới insert.

---

## 8. `TOP` / `LIMIT` / `FETCH`

| | SQL Server | PostgreSQL |
|---|---|---|
| Dialect | `TOP (n) [PERCENT] [WITH TIES]` | `LIMIT n OFFSET m` |
| ANSI | `OFFSET … FETCH` | `OFFSET … FETCH` |
| `WITH TIES` | với `TOP` | `FETCH FIRST n ROWS WITH TIES` |

```sql
-- SQL Server
SELECT TOP (10) WITH TIES *
FROM dbo.Orders
ORDER BY Total DESC;
-- Không kết hợp TOP + OFFSET FETCH trong một query

-- PostgreSQL
SELECT * FROM orders ORDER BY total DESC LIMIT 10 OFFSET 0;

-- ANSI (cả hai)
SELECT * FROM orders
ORDER BY total DESC
OFFSET 0 ROWS FETCH NEXT 10 ROWS ONLY;
```

**Ghi chú:** Thiếu `ORDER BY` thì `TOP`/`LIMIT` = “n hàng tùy plan”. Offset lớn đắt — keyset pagination [select.md](select.md). `FETCH` T-SQL còn là `FETCH NEXT FROM cursor` — khác clause `OFFSET FETCH`. `WAIT FOR` 19 không liên quan `FETCH`.

---

## 9. `GRAPH_TABLE` / `MATCH` (PostgreSQL 19)

SQL/PGQ: property graph = **metadata** trên bảng vertex/edge đã có. `GRAPH_TABLE` + `MATCH` rewrite thành join — cùng planner, không engine graph riêng. Index PK/FK vẫn bắt buộc.

```sql
CREATE PROPERTY GRAPH shop
    VERTEX TABLES (customers, orders)
    EDGE TABLES (
        customer_orders SOURCE customers DESTINATION orders
    );

SELECT name
FROM GRAPH_TABLE (
    shop
    MATCH (c IS customers)-[IS customer_orders]->(o IS orders)
    COLUMNS (c.name)
);
```

Cần PK/FK hoặc `KEY` / `SOURCE KEY` / `DESTINATION KEY`. Label reserved (`"order"`) phải quote. `DROP PROPERTY GRAPH` **không** drop bảng.

**Chưa có (19):** variable-length `{1,4}`, shortest path, path variable đầy đủ. Path cố định hoặc recursive CTE.

SQL Server 2025 **không** SQL/PGQ. SQL Graph cũ `AS NODE` / `AS EDGE` / `MATCH` **không** cùng chuẩn — đừng port pattern PGQ sang SS hay ngược.

**Ghi chú:** **Beta**. `EXPLAIN` = join. Thiếu index FK = nested loop nặng. `MATCH` / `COLUMNS` / `VERTEX` / `EDGE` / `PROPERTY` `GRAPH` là keyword contextual. Quyền `USAGE` graph vs bảng — đọc GRANT docs 19, đừng bịa. Chi tiết [select.md](select.md), [ddl.md](ddl.md). Hybrid vector + full-text SS **không** phải `GRAPH_TABLE` — [typesystem.md](typesystem.md).

Hai session — metadata vs data:

```text
T1: DROP PROPERTY GRAPH shop;            -- bảng customers/orders còn
T2: SELECT * FROM customers;             -- OK
    SELECT * FROM GRAPH_TABLE (shop …);  -- lỗi: graph không còn
```

---

## 10. `REPACK` (PostgreSQL 19)

Thống nhất `VACUUM FULL` (compact heap) + `CLUSTER` (sort theo index). Lệnh cũ **còn chạy**. Keyword mới, **không** trong transaction block.

```sql
REPACK employees;
REPACK employees USING INDEX employees_pkey;
REPACK (CONCURRENTLY, ANALYZE) employees USING INDEX employees_pkey;
REPACK (VERBOSE) employees;
```

Mặc định `ACCESS EXCLUSIVE` suốt copy. `CONCURRENTLY`: copy dưới `SHARE UPDATE EXCLUSIVE` + logical decoding vào stash; exclusive **lúc swap**. GUC `max_repack_replication_slots`.

Hạn chế (**beta**, đọc reference): partitioned / unlogged / catalog; deadlock lock upgrade lúc swap. Không thay `TRUNCATE`.

SQL Server tương đương gần: `ALTER INDEX … REBUILD` (`ONLINE = ON` historically Enterprise — [internal.md](internal.md) edition). Không logical decoding, không keyword `REPACK`.

**Ghi chú:** Slot + WAL lúc concurrent. Job đêm: thử replica trước. Autovacuum song song **không** thay `REPACK` khi bloat nặng. [ddl.md](ddl.md), [indexes.md](indexes.md). `CLUSTER` keyword cũ ≠ `REPACK` nhưng cùng họ rewrite heap.

`REPACK` unquoted làm tên bảng: contextual — vẫn tránh. `VACUUM` / `ANALYZE` / `VERBOSE` / `CONCURRENTLY` đi cùng.

---

## 11. `FOR PORTION OF` (PostgreSQL 19)

Application-time: cắt range validity rồi update/delete một đoạn. Cần cột range + `WITHOUT OVERLAPS` (PG **18+**).

```sql
UPDATE products
FOR PORTION OF valid_at FROM DATE '2026-01-01' TO DATE '2026-07-01'
SET price = 99
WHERE sku = 'ABC';

DELETE FROM products
FOR PORTION OF valid_at ('[2028-01-01,)')
WHERE sku = 'ABC';
```

Cắt range, insert leftover (0–2 leftover với range; multirange: 0–1). Bound **hằng** (`now()` được; **không** column ref). Hàm `range_minus_multi` / `multirange_minus_multi`.

Race `READ COMMITTED`: leftover/lost portion nếu hai txn cắt cùng hàng — **`SELECT FOR UPDATE`** cùng predicate + portion trước. RR/SSI: khóa đó không bắt buộc theo docs nhưng test.

**Không** phải SQL Server system-versioned `FOR SYSTEM_TIME`. Cùng chữ `FOR`, khác máy.

**Ghi chú:** **Beta**. Constraint `WITHOUT OVERLAPS` fail nếu leftover chồng hàng khác. Không dùng cho bitemporal đầy đủ trừ khi tự quản system-time. [dml.md](dml.md), [constraints.md](constraints.md). Keyword `PORTION` contextual.

---

## 12. `BEGIN` / giao dịch / `WAIT FOR`

| Keyword | SQL Server | PostgreSQL |
|---|---|---|
| Mở txn | `BEGIN TRAN[SACTION]` | `BEGIN` / `START TRANSACTION` |
| `BEGIN` một mình | Khối `BEGIN…END` — **không** mở txn | Mở txn |
| `COMMIT` / `ROLLBACK` | Có | Có |
| Savepoint | `SAVE TRAN` | `SAVEPOINT` |
| Isolation | `SET TRANSACTION ISOLATION LEVEL` | Giống tên, **khác guarantee** |

```sql
-- SQL Server: KHÔNG có transaction
BEGIN
    SELECT 1;
END;

BEGIN TRANSACTION;
COMMIT;

-- PostgreSQL
BEGIN;
COMMIT;
```

**Ghi chú:** Đây là bẫy port số 1. Isolation: [transactions.md](transactions.md).

### `WAITFOR` vs `WAIT FOR`

```sql
-- SQL Server: chờ thời gian / thời điểm (T-SQL batch)
WAITFOR DELAY '00:00:05';
WAITFOR TIME '23:00';

-- PostgreSQL 19 (standby): chờ LSN — read-your-writes
-- Primary, sau COMMIT
SELECT pg_current_wal_insert_lsn();   -- ví dụ 0/306EE20

-- Standby (top-level, isolation ≤ READ COMMITTED)
WAIT FOR LSN '0/306EE20';
-- hoặc
WAIT FOR LSN '0/306EE20' WITH (MODE 'standby_replay', TIMEOUT '200ms', NO_THROW);
SELECT * FROM orders WHERE id = 42;
```

`MODE`: `standby_replay` (mặc định, cần cho RYW) / `standby_flush` / `standby_write` / `primary_flush`. Timeout không `NO_THROW` → ERROR. Chi tiết [transactions.md](transactions.md) §11.

SQL Server AG: không `WAIT FOR` LSN. Sync commit đắt; async = stale read.

**Ghi chú:** `WAIT FOR` ≠ `WAITFOR DELAY`. Sai MODE/chỗ chạy (standby lệnh trên primary) → lỗi hoặc `not in recovery`. [internal.md](internal.md).

---

## 13. DDL: `CREATE` / `ALTER` / `DROP`

```sql
CREATE TABLE t (id int PRIMARY KEY);
ALTER TABLE t ADD COLUMN note text;      -- PG; SQL Server: ADD note nvarchar(100)
DROP TABLE IF EXISTS t;                  -- cả hai (SS 2016+)
```

Nhóm object: `TABLE` `VIEW` `INDEX` `SCHEMA` `DATABASE` `TYPE` `DOMAIN` `SEQUENCE` `FUNCTION` `PROCEDURE` `TRIGGER` `MATERIALIZED VIEW` `PROPERTY GRAPH`.

**Ghi chú:** PG DDL hầu hết transactional; SQL Server nhiều DDL commit ngầm — [ddl.md](ddl.md), [transactions.md](transactions.md). `CREATE OR REPLACE` phổ biến PG; T-SQL `CREATE OR ALTER` (proc/view/function, 2016 SP1+). `CONCURRENTLY` (PG index/repack) không trong txn.

`CREATE VECTOR INDEX` SS **PREVIEW** — `VECTOR` contextual. `CREATE JSON INDEX` **PREVIEW** on-prem. `CREATE EXTERNAL MODEL` — AI, không keyword graph.

`ALTER TABLE … MERGE PARTITIONS` / `SPLIT PARTITION` PG **19 beta** — [ddl.md](ddl.md). Keyword `SPLIT`/`MERGE` DDL ≠ `MERGE` DML.

---

## 14. Constraint

`CONSTRAINT` `PRIMARY` `FOREIGN` `UNIQUE` `CHECK` `REFERENCES` `DEFAULT` `NOT NULL` `DEFERRABLE` (PG) `EXCLUSION` (PG) `ENFORCED` (PG **19** CHECK).

```sql
CREATE TABLE t (
    id int PRIMARY KEY,
    email text NOT NULL UNIQUE,
    parent_id int REFERENCES t (id),
    CHECK (id > 0)
);
```

**Ghi chú:** `DEFAULT` vừa keyword constraint vừa `DEFAULT VALUES` lúc insert. `PRIMARY` không dùng làm tên cột unquoted. Deferred: chỉ PostgreSQL — [constraints.md](constraints.md). `WITHOUT OVERLAPS` 18+ đi với PK temporal — cần cho `FOR PORTION OF`.

PG 19: `ALTER … CONSTRAINT … [NOT] ENFORCED` trên **CHECK**. Khác `NOT VALID`.

---

## 15. Window: `OVER` / `FILTER` / `IGNORE NULLS`

```sql
SELECT SUM(total) OVER (PARTITION BY customer_id ORDER BY id) AS running
FROM orders;

-- PostgreSQL
SELECT SUM(total) FILTER (WHERE status = 'paid') FROM orders;
SELECT LAG(value) IGNORE NULLS OVER (ORDER BY ts);   -- PG 19
SELECT LAST_VALUE(value) RESPECT NULLS OVER (
    ORDER BY ts
    ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
);
```

Hàm 19: `lead`, `lag`, `first_value`, `last_value`, `nth_value`. Mặc định `RESPECT NULLS`.

**Ghi chú:** `FILTER` aggregate: PG; SQL Server dùng `SUM(CASE WHEN …)`. `GROUPS` frame: PG. `IGNORE NULLS` **không** phải toán tử, không dùng trong `WHERE` — [operators.md](operators.md), [window-functions.md](window-functions.md). Frame `LAST_VALUE` mặc định đến `CURRENT ROW` — `IGNORE NULLS` không sửa frame sai. SQL Server: `IGNORE NULLS` trên offset một số phiên bản — **không** giả `NTH_VALUE` (SS không có). `PIVOT`/`UNPIVOT`: chỉ SQL Server (keyword). `WINDOW` clause đặt tên frame.

---

## 16. `GROUP BY ALL`

PostgreSQL **19**: group mọi cột non-aggregate / non-window trên `SELECT` list.

```sql
SELECT customer_id, status, count(*)
FROM orders
GROUP BY ALL;
```

Tiện, nhưng **đổi list SELECT = đổi grouping** — review như đổi `GROUP BY` tường minh.

SQL Server: không `GROUP BY ALL` (có `GROUP BY` + `CUBE`/`ROLLUP`/`GROUPING SETS`). `SELECT ALL` (vs `DISTINCT`) khác hẳn.

**Ghi chú:** `ALL` đã reserved nhiều ngữ cảnh (`FETCH FIRST n ROWS ONLY` vs `WITH TIES`, `UNION ALL`, `> ALL`). Parser 19 thêm vị trí sau `GROUP BY`. Cột mới trên `SELECT` lọt grouping — bẫy PR “thêm cột hiển thị”. Optimizer 19 `GROUP BY` subquery target list — [select.md](select.md).

Không liên quan `PREVIEW_FEATURES`.

---

## 17. Điều khiển luồng

```sql
-- SQL Server (T-SQL batch — keyword SQL)
IF @x > 0
BEGIN
    PRINT 'ok';
END
ELSE
    THROW 50000, 'bad', 1;

WHILE @i < 10
BEGIN
    SET @i += 1;
    CONTINUE;
    BREAK;
END
```

```sql
-- PostgreSQL: IF/LOOP chỉ trong hàm/DO (PL/pgSQL), không phải SQL thường
DO $$
BEGIN
    IF x > 0 THEN
        RAISE NOTICE 'ok';
    END IF;
END $$;
```

**Ghi chú:** `ELSIF`, `FOREACH`, `EXCEPTION`, `LOOP` là PL/pgSQL. `GO` không phải keyword engine. `RETURN`/`RETURNS` routine — [routines.md](routines.md). `THROW` vs `RAISERROR` T-SQL; PG `RAISE`.

`DO $$ … $$` (anonymous block) ≠ `ON CONFLICT DO SELECT` / `DO UPDATE` / `DO NOTHING`. Cùng chữ `DO`, khác vị trí.

`WAITFOR` là T-SQL control-ish (chờ), không `WHILE`.

---

## 18. `GRANT` / `REVOKE` / `DENY`

`DENY` chỉ SQL Server (thắng `GRANT` trừ sysadmin). PG: `GRANT`/`REVOKE`, không `DENY`.

```sql
-- SQL Server
GRANT SELECT ON dbo.Orders TO app;
DENY DELETE ON dbo.Orders TO app;

-- PostgreSQL
GRANT SELECT ON app.orders TO app;
REVOKE INSERT ON app.orders FROM app;
ALTER … OWNER TO …
```

`AUTHORIZATION` lúc `CREATE SCHEMA`. Principal, `PUBLIC`, schema, RLS, ownership: [permissions.md](permissions.md). `SECURITY DEFINER` / `EXECUTE AS`: [routines.md](routines.md) + `search_path`.

PG 19: `GRANT`/`REVOKE … GRANTED BY` — role hiệu lực khi ghi ACL. `USAGE` trên property graph — đọc docs, không bịa quyền. SQL Server 2025: Purview policies discontinued → role `##MS_*##` — [internal.md](internal.md), không keyword SQL mới trong file này.

---

## 19. SQL Server 2025 — built-in mới

Không đợt reserved word lớn; thêm **type / hàm / config**. Tên có thể đụng cột cũ.

| Tên | Vai trò | Ghi chú |
|---|---|---|
| `VECTOR` / `vector(n)` | Kiểu | Quote cột tên `vector` nếu đụng |
| `VECTOR_DISTANCE` / `VECTOR_NORM` / `VECTOR_NORMALIZE` / `VECTORPROPERTY` | Hàm | **GA** |
| `VECTOR_SEARCH` / `CREATE VECTOR INDEX` | ANN | **PREVIEW** + `PREVIEW_FEATURES` |
| `AI_GENERATE_EMBEDDINGS` / `AI_GENERATE_CHUNKS` | Hàm | Model REST; credential tách |
| `JSON_OBJECTAGG` / `JSON_ARRAYAGG` | Aggregate | 2025; on-prem nhiều **PREVIEW** |
| `JSON_CONTAINS` / `CREATE JSON INDEX` | JSON | **PREVIEW** on-prem — [operators.md](operators.md) |
| `REGEXP_LIKE` … | Regex | **GA** |
| `CURRENT_DATE` | Hàm `date` | **2025** — đụng cột cùng tên |
| `UNISTR` / `PRODUCT` | Hàm | **2025** |
| `BASE64_ENCODE` / `BASE64_DECODE` | Hàm | Không literal — [literals.md](literals.md) |
| `PREVIEW_FEATURES` | Database scoped | Bật preview |
| `CREATE EXTERNAL MODEL` | AI | Credential, không hard-code |
| `SUBSTRING` length optional / `DATEADD` bigint | Hàm | **2025** |

Fuzzy `EDIT_DISTANCE*` / `JARO_WINKLER*`: **PREVIEW**. CES / mirroring: kiến trúc log — [internal.md](internal.md), [concurrency.md](concurrency.md). Không nhét CES vào keyword list như `SELECT`.

`CURRENT_DATE` không phải literal — [typesystem.md](typesystem.md) §4.4, [literals.md](literals.md).

---

## 20. PostgreSQL 19 — clause mới

| Keyword / clause | Mục đích | Ghi chú |
|---|---|---|
| `REPACK` [`CONCURRENTLY`] | Rebuild bảng/index | Không trong txn; **beta 19** |
| `WAIT` `FOR` | Chờ LSN standby | ≠ `WAITFOR` T-SQL |
| `GRAPH_TABLE` `MATCH` `COLUMNS` | SQL/PGQ | Path cố định 19; **beta** |
| `PROPERTY` `GRAPH` `VERTEX` `EDGE` | DDL graph | `DROP` không drop bảng |
| `FOR PORTION OF` | Temporal DML | Cần 18 `WITHOUT OVERLAPS` |
| `IGNORE NULLS` / `RESPECT NULLS` | Window | Không `WHERE` |
| `DO SELECT` | `ON CONFLICT DO SELECT` | Khóa hàng đã có; **beta** |
| `GROUP BY ALL` | Group list SELECT | Đổi SELECT = đổi group |
| `CHECK [NOT] ENFORCED` | Constraint | Khác `NOT VALID` |

```sql
INSERT INTO t (id, val) VALUES (1, 'x')
ON CONFLICT (id) DO SELECT
FOR UPDATE
RETURNING *;
```

Conflict: **không** update, **trả** hàng đã có (`RETURNING`), tùy chọn khóa `FOR UPDATE` / `SHARE`. Idempotent “insert or return existing”. `DO NOTHING` không `RETURNING` hàng conflict (trừ khi không conflict). `DO UPDATE` ghi.

**Ghi chú:** Unique violation vẫn cần index unique. Race: `DO SELECT FOR UPDATE` vs `DO UPDATE` khác nghiệp vụ. [dml.md](dml.md).

`json_array()` rỗng → `[]` là **hàm** breaking, không keyword mới. JIT off / strings always on: GUC — [dialects.md](dialects.md), [literals.md](literals.md).

---

## 21. Hay đụng identifier

Tránh unquoted (cột/bảng/schema). Quote được nhưng ORM/graph/SQL động khổ.

`order`, `user`, `group`, `table`, `index`, `key`, `value`, `type`, `name`, `date`, `time`, `level`, `offset`, `window`, `rank`, `left`, `right`, `inner`, `check`, `default`, `constraint`, `primary`, `references`, `session_user`, `current_user`, `current_date`, `current_timestamp`, `json`, `xml`, `vector`, `end`, `file`, `plan`, `limit`, `both`, `all`, `any`, `some`, `role`, `grant`, `match`, `filter`, `over`, `range`, `rows`, `lead`, `lag`, `first`, `next`, `percent`, `ties`, `output`, `merge`, `apply`, `pivot`, `identity`, `national`, `zone`, `precision`, `interval`, `cascade`, `restrict`, `replace`, `return`, `language`, `external`, `cursor`, `fetch`, `deallocate`, `declare`, `execute`, `backup`, `restore`, `waitfor`, `partition`, `clusters`/`cluster`, `analyse`/`analyze`, `verbose`, `freeze`, `repack`, `portion`, `graph`, `vertex`, `edge`, `columns`, `wait`.

```sql
-- PostgreSQL: USER reserved
CREATE TABLE user (id int);              -- lỗi
CREATE TABLE "user" (id int);            -- OK, khổ về sau
CREATE TABLE app_user (id int);          -- tốt hơn

-- SQL Server: USER là function/keyword; [user] quote
CREATE TABLE dbo.[User] (Id int);
-- OFFSET / WINDOW / RANK trong tên cột + clause trùng chữ
```

`json` / `vector` **2025** dễ đụng cột sẵn. `current_date` thành hàm 2025 — tên cột `current_date` unquoted trong `SELECT current_date` đổi nghĩa.

PostgreSQL: `user` / `current_user` là function-like keywords (`SELECT user`).

`MATCH` + graph 19: cột `match` trong `GRAPH_TABLE` khó đọc. `ALL` + `GROUP BY ALL`.

---

## 22. Hai session — ví dụ làm việc

### 22.1 `BEGIN` port

```text
T1 (SS): BEGIN SELECT 1; END;            -- khối, auto-commit mặc định
T2 (PG): BEGIN; SELECT 1;                -- txn mở, T2 giữ lock/xmin đến COMMIT
-- Pool PG: idle in transaction — [internal.md](internal.md)
```

### 22.2 `WAITFOR` vs `WAIT FOR`

```text
T1 (SS): WAITFOR DELAY '00:00:01'; SELECT * FROM dbo.Orders WHERE Id = 42;
         -- chỉ ngủ, không đợi replica
T2 (PG standby): WAIT FOR LSN '…' WITH (MODE 'standby_replay'); SELECT …
         -- đúng LSN mới thấy commit primary
```

### 22.3 `CURRENT_DATE` đụng cột

```text
T1 (SS 2022): SELECT current_date FROM dbo.T;     -- cột
T2 (SS 2025): SELECT current_date FROM dbo.T;     -- HÀM date, không cột — hoặc ambiguous
-- Sửa: SELECT t.current_date FROM dbo.T AS t  hoặc đổi tên cột
```

### 22.4 `DO SELECT` vs `DO UPDATE`

```text
T1: INSERT … ON CONFLICT (id) DO UPDATE SET val = EXCLUDED.val;
    -- ghi đè
T2: INSERT … ON CONFLICT (id) DO SELECT FOR UPDATE RETURNING *;
    -- không ghi, trả + khóa hàng cũ
```

### 22.5 `GROUP BY ALL` thêm cột

```text
T1: SELECT customer_id, count(*) FROM orders GROUP BY ALL;           -- group customer_id
T2: SELECT customer_id, status, count(*) FROM orders GROUP BY ALL;   -- group hai cột — count đổi
```

### 22.6 `FOR PORTION OF` race

```text
T1: UPDATE … FOR PORTION OF valid_at FROM DATE '2026-01-01' TO DATE '2026-07-01' …
T2: cùng hàng, portion khác, READ COMMITTED không FOR UPDATE
    -- leftover chồng / mất đoạn — [dml.md](dml.md)
```

### 22.7 `VECTOR` identifier vs type

```text
T1: CREATE TABLE dbo.Vector (Id int);           -- tên bảng
T2: CREATE TABLE dbo.Doc (Embedding vector(3)); -- kiểu 2025
    SELECT vector FROM dbo.Something;           -- cột vs kiểu — quote nếu cần
```

---

## 23. Best practices & checklist

- Đặt tên nghiệp vụ (`app_user`, `sort_order`) thay vì quote reserved.
- Schema-qualify; đừng `user` làm bảng rồi `SET search_path`.
- `;` trước `WITH` CTE trên T-SQL.
- `BEGIN TRAN` vs `BEGIN` — đọc dialect trước khi review txn.
- `OUTPUT`/`RETURNING`, `TOP`/`LIMIT`, `APPLY`/`LATERAL` ghi rõ khi port.
- `MERGE`: test race; cân nhắc `ON CONFLICT` (PG); 19 `DO SELECT` khi chỉ cần hàng cũ.
- Preview/beta (`VECTOR_SEARCH`, `GRAPH_TABLE`, `REPACK`, `FOR PORTION OF`): không production mặc định.
- `WAITFOR` ≠ `WAIT FOR`. `FOR SYSTEM_TIME` ≠ `FOR PORTION OF`.
- `GROUP BY ALL`: review như đổi grouping.
- `CURRENT_DATE` / `VECTOR` / `JSON`: soi cột cũ trước nâng 2025.
- Tra `pg_get_keywords` khi đặt tên mới trên PG.

---

## 24. Bẫy khi review

- `BEGIN` T-SQL như mở txn.
- `WITH (NOLOCK)` bị đọc thành CTE.
- `FETCH` cursor vs `OFFSET FETCH`.
- `WAITFOR` vs `WAIT FOR`.
- `MERGE` SQL Server copy lên PG thiếu `BY SOURCE` / isolation.
- `UPDATE … FROM` fan-out PG.
- `SELECT user` tưởng cột.
- `SELECT current_date` sau khi nâng SQL 2025 — cột cùng tên.
- `FILTER` / `IGNORE NULLS` giả có trên mọi hàm SQL Server.
- `NATURAL JOIN` / tên cột `date` thêm vào bảng làm join đổi.
- `GO` trong keyword list — không phải T-SQL.
- `TRUNCATE` như `DELETE` (trigger, identity, FK).
- `DENY` port sang PG.
- `GRAPH_TABLE` kỳ vọng shortest path / `{1,4}` trên 19.
- `REPACK` trong `BEGIN` block.
- `DO SELECT` tưởng `DO UPDATE`.
- `GROUP BY ALL` + thêm cột SELECT.
- `MATCH` MERGE vs `MATCH` PGQ vs SQL Graph SS.
- `VECTOR_SEARCH` prod không `PREVIEW_FEATURES`.
- Port `REPACK` → `REORGANIZE` (không cùng) — [internal.md](internal.md).

---

## 25. Version gates

| Mục | SQL Server | PostgreSQL |
|---|---|---|
| `CREATE OR ALTER` | 2016 SP1+ | `CREATE OR REPLACE` lâu |
| `DROP IF EXISTS` | 2016+ | lõi |
| `MERGE` | lâu (cẩn thận) | **15+** |
| `ON CONFLICT` | — (`MERGE`/hint) | **9.5+**; `DO SELECT` **19** |
| `OFFSET FETCH` | 2012+ | lâu |
| `IS DISTINCT FROM` | **2022+** | lõi |
| `JSON_OBJECTAGG` | **2025** (on-prem **PREVIEW** nhiều phần) | lâu |
| `REGEXP_LIKE` | **2025** | `~` lâu |
| `CURRENT_DATE` | **2025** | lõi |
| `VECTOR` type | **2025 GA** | pgvector ext |
| `VECTOR_SEARCH` | **2025 PREVIEW** | — |
| `UNISTR` / `PRODUCT` | **2025** | — / thủ công |
| `GRAPH_TABLE` / PGQ | — (SQL Graph khác) | **19** (**beta**) |
| `REPACK` | rebuild index | **19** |
| `WAIT FOR` LSN | — (`WAITFOR` khác) | **19** |
| `FOR PORTION OF` | `FOR SYSTEM_TIME` khác | **19** |
| `IGNORE NULLS` window | — | **19** |
| `GROUP BY ALL` | — | **19** |
| CHECK `[NOT] ENFORCED` | — | **19** |
| `FILTER` aggregate | — | lõi |
| `LATERAL` | `APPLY` | lõi |
| `DENY` | lõi | — |

SELECT logic: [select.md](select.md). Isolation keyword: [transactions.md](transactions.md). Identifier quoting: [dialects.md](dialects.md). Kiểu `vector`/`json`: [typesystem.md](typesystem.md). Process/SKU: [internal.md](internal.md).

---

## Phụ lục A. Keyword vs hàm vs kiểu — cùng chữ

Parser không quan tâm “ý định nghiệp vụ”. Cùng token, khác vị trí.

| Token | Vị trí A | Vị trí B |
|---|---|---|
| `SELECT` | Bắt đầu query | `ON CONFLICT DO SELECT` (PG **19**) |
| `MATCH` | `MERGE … WHEN MATCHED` | `GRAPH_TABLE … MATCH` (PG **19**); SQL Graph SS |
| `FOR` | `FOR XML` / `FOR JSON` / cursor `FOR` | `FOR PORTION OF` / `FOR UPDATE` / `WAIT FOR` |
| `WAIT` | — | `WAIT FOR` (hai token, PG **19**) |
| `WAITFOR` | T-SQL delay | không có trên PG |
| `ALL` | `UNION ALL` / `> ALL` / `FETCH … ALL` | `GROUP BY ALL` (PG **19**) |
| `DO` | `DO $$` PL block | `DO UPDATE` / `DO NOTHING` / `DO SELECT` |
| `VECTOR` | Kiểu / hàm SS **2025** | Tên cột/bảng |
| `CURRENT_DATE` | Hàm (SS **2025**, PG lõi) | Tên cột |
| `JSON` | Kiểu SS **PREVIEW** on-prem / PG | Tên cột |
| `FILTER` | Aggregate PG | Tên cột; không T-SQL aggregate |
| `OVER` | Window | Tên cột |
| `MERGE` | DML upsert | `ALTER TABLE MERGE PARTITIONS` (PG **19**) |
| `COLUMNS` | `GRAPH_TABLE … COLUMNS` | tên cột (plural) |

Review: highlight token rồi hỏi *vị trí*. Đừng grep `SELECT` trong `DO SELECT` rồi bảo “query lồng”.

---

## Phụ lục B. `ON CONFLICT DO SELECT` — keyword path

```sql
INSERT INTO t (id, val) VALUES (1, 'x')
ON CONFLICT (id) DO SELECT
FOR UPDATE
RETURNING *;
```

Thứ tự token: `INSERT` … `ON` `CONFLICT` … `DO` `SELECT` [`FOR` `UPDATE`|`SHARE`] `RETURNING`.

```text
T1: INSERT trùng id, DO UPDATE SET val = 'x'     -- ghi
T2: INSERT trùng id, DO SELECT FOR UPDATE        -- không ghi, khóa, RETURNING hàng cũ
T3: INSERT trùng id, DO NOTHING                  -- không hàng RETURNING conflict
```

Không `OUTPUT`. Không T-SQL. **Beta 19**. Unique index bắt buộc. [dml.md](dml.md).

`FOR UPDATE` đây là lock clause của `DO SELECT`, không `FOR PORTION OF`, không `WAIT FOR`.

---

## Phụ lục C. SQL Graph SS vs SQL/PGQ — keyword đừng trộn

| | SQL Server Graph (cũ) | PostgreSQL 19 SQL/PGQ |
|---|---|---|
| DDL | `AS NODE` / `AS EDGE` | `CREATE PROPERTY GRAPH` `VERTEX TABLES` `EDGE TABLES` |
| Query | `MATCH` trong `SELECT` (syntax Graph) | `GRAPH_TABLE ( … MATCH … COLUMNS …)` |
| Engine | Graph tables riêng | Metadata + rewrite join |
| 2025 | **Không** nâng thành PGQ | **Beta** path cố định |

Port `MATCH (a)-[e]->(b)` SS → `GRAPH_TABLE` = viết lại schema, không tìm-thay keyword. Vector hybrid search SS không dùng `MATCH`.

---

## Phụ lục D. `REPACK` vs `VACUUM` vs `CLUSTER` — token

```sql
VACUUM (FULL, ANALYZE) employees;        -- cũ, còn chạy
CLUSTER employees USING employees_pkey;  -- cũ, còn chạy
REPACK (CONCURRENTLY, ANALYZE) employees USING INDEX employees_pkey;  -- 19
```

Cả ba *rewrite/sắp heap* theo nghĩa vận hành, **ba keyword**. Job cron `CLUSTER` không tự thành `REPACK (CONCURRENTLY)`. `VACUUM` không `CONCURRENTLY` kiểu index. `REPACK` cấm transaction block — `BEGIN; REPACK …` lỗi.

SQL Server: không token này. `ALTER INDEX … REBUILD` / `REORGANIZE` — edition `ONLINE` — [internal.md](internal.md).
