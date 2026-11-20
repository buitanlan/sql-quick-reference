# Từ khóa (Keywords)

> **Baseline:** SQL Server **2025** · PostgreSQL **19** (GA 19/11/2026).<br>
> Reserved word ≠ keyword. Unquoted identifier trùng reserved → lỗi parse. Danh sách **không** giống nhau giữa hai engine.

Từ khóa SQL là tín hiệu cho parser, không phải API gọi được. File này **không** liệt kê hết reserved word (xem catalog / Learn). Mỗi nhóm quan trọng: mục đích → ví dụ hai dialect → ghi chú / version. Identifier hay đụng: §18. Quy ước quote: [dialects.md](dialects.md).

PostgreSQL 19 GA (19/11/2026) giữ `REPACK`, `WAIT FOR`, `ON CONFLICT DO SELECT` và window `IGNORE NULLS`. SQL Server 2025: kiểu `vector`, `CURRENT_DATE`, JSON, và fuzzy (`EDIT_DISTANCE` / `JARO_WINKLER_*` từ **CU11**) là GA. Vector index, `VECTOR_SEARCH`, half-precision vector và CES còn **PREVIEW**.

---

## Mục lục

- [1. Quy tắc & triết lý](#1-quy-tắc--triết-lý)
- [2. `SELECT`](#2-select)
- [3. `WITH` (CTE)](#3-with-cte)
- [4. `JOIN` / `LATERAL` / `APPLY`](#4-join--lateral--apply)
- [5. `MERGE`](#5-merge)
- [6. `INSERT` / `UPDATE` / `DELETE` / `TRUNCATE`](#6-insert--update--delete--truncate)
- [7. `RETURNING` / `OUTPUT`](#7-returning--output)
- [8. `TOP` / `LIMIT` / `FETCH`](#8-top--limit--fetch)
- [9. `REPACK` (PostgreSQL 19)](#9-repack-postgresql-19)
- [10. `BEGIN` / giao dịch / `WAIT FOR`](#10-begin--giao-dịch--wait-for)
  - [`WAITFOR` vs `WAIT FOR`](#waitfor-vs-wait-for)
- [11. DDL: `CREATE` / `ALTER` / `DROP`](#11-ddl-create--alter--drop)
- [12. Constraint](#12-constraint)
- [13. Window: `OVER` / `FILTER` / `IGNORE NULLS`](#13-window-over--filter--ignore-nulls)
- [14. Điều khiển luồng](#14-điều-khiển-luồng)
- [15. `GRANT` / `REVOKE` / `DENY`](#15-grant--revoke--deny)
- [16. SQL Server 2025 — built-in mới](#16-sql-server-2025--built-in-mới)
- [17. PostgreSQL 19 — clause mới](#17-postgresql-19--clause-mới)
- [18. Hay đụng identifier](#18-hay-đụng-identifier)
- [19. Hai session — ví dụ làm việc](#19-hai-session--ví-dụ-làm-việc)
  - [19.1 `BEGIN` port](#191-begin-port)
  - [19.2 `WAITFOR` vs `WAIT FOR`](#192-waitfor-vs-wait-for)
  - [19.3 `CURRENT_DATE` đụng cột](#193-current_date-đụng-cột)
  - [19.4 `DO SELECT` vs `DO UPDATE`](#194-do-select-vs-do-update)
  - [19.5 `VECTOR` identifier vs type](#195-vector-identifier-vs-type)
- [20. Best practices & checklist](#20-best-practices--checklist)
- [21. Bẫy khi review](#21-bẫy-khi-review)
- [22. Version gates](#22-version-gates)
- [Phụ lục A. Keyword vs hàm vs kiểu — cùng chữ](#phụ-lục-a-keyword-vs-hàm-vs-kiểu--cùng-chữ)
- [Phụ lục B. `ON CONFLICT DO SELECT` — keyword path](#phụ-lục-b-on-conflict-do-select--keyword-path)
- [Phụ lục C. `REPACK` vs `VACUUM` vs `CLUSTER` — token](#phụ-lục-c-repack-vs-vacuum-vs-cluster--token)
- [Nguồn chính thức](#nguồn-chính-thức)

---

## 1. Quy tắc & triết lý

- **Reserved:** không dùng làm identifier trừ khi quote (`"order"`, `[order]`).
- **Unreserved / contextual:** keyword chỉ ở vị trí nhất định (`name`, `value`, `type` trên PostgreSQL; `VALUE` trong `JSON_OBJECTAGG`).
- Danh sách lệch: `USER`, `OFFSET`, `WINDOW`, `FILTER`, `OUTPUT`, `APPLY`, `TOP`, `LIMIT`, `VECTOR`, `REPACK`, `MATCH`.
- Tra cứu: PostgreSQL `SELECT word, catcode, catdesc FROM pg_get_keywords();` phân **4 mức `catcode`**:
  - `U` (*unreserved*): dùng tự do làm tên bảng/cột/hàm/kiểu không cần quote (vd `name`, `value`).
  - `C` (*unreserved, cannot be function or type*): dùng làm tên bảng/cột được, nhưng không làm tên hàm/kiểu (vd `int`, `coalesce`).
  - `T` (*reserved, can be function or type*): không làm tên bảng/cột unquoted, nhưng dùng được làm tên hàm/kiểu (vd `join`, `like`, `is`).
  - `R` (*reserved*): cấm hoàn toàn khi không quote (vd `select`, `order`, `user`).
- SQL Server: tra *Reserved Keywords (Transact-SQL)* trên Learn — không có catalog view đầy đủ tương đương.

```sql
SELECT * FROM "order";                   -- PG; SQL Server chỉ chạy khi QUOTED_IDENTIFIER ON
SELECT * FROM [order];                   -- SQL Server: luôn là identifier kể cả QUOTED_IDENTIFIER OFF
```

**Ảnh hưởng `QUOTED_IDENTIFIER` trên SQL Server:** Khi `SET QUOTED_IDENTIFIER ON` (mặc định ở SSMS/driver hiện đại và bắt buộc cho indexed view, filtered index, index trên computed column, XML/JSON), `"order"` là identifier chuẩn ANSI. Khi `OFF`, `"order"` bị parse thành **string literal** — chỉ `[order]` luôn an toàn bất kể session setting.

Quote cả đời vì tên `user` “chạy được” hôm nay — schema dump, ORM, graph query dễ gãy. Đổi tên (`app_user`) tốt hơn quote.

**Ghi chú:** Keyword mới 19/2025 thường *contextual*: `VECTOR` là kiểu/hàm SS; cột `vector` unquoted có thể parse lệch. `CURRENT_DATE` 2025 biến cột cùng tên thành hàm trong `SELECT current_date`. `REPACK` không xuất hiện T-SQL.

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

- `SELECT` không `ORDER BY` → thứ tự không xác định. `DISTINCT` + `ORDER BY`: cả SQL Server lẫn PostgreSQL đều cấm sắp theo cột không nằm trong `SELECT DISTINCT` list (PostgreSQL chỉ cho biểu thức tính từ cột có sẵn trong list, hoặc dùng `DISTINCT ON`).
- `SELECT @v = col FROM t` T-SQL gán biến (không xác định nếu nhiều hàng) — khác `SELECT` trả result set.
- Alias `SELECT` không dùng trong `WHERE` cùng mức.
- `ON CONFLICT DO SELECT` **không** bắt đầu bằng `SELECT` — clause của `INSERT` (§17, [dml.md](dml.md)).

---

## 3. `WITH` (CTE)

- **Mục đích:** Đặt tên subquery; `RECURSIVE` duyệt đồ thị/cây. Trên T-SQL, `WITH` còn là table hint (`WITH (NOLOCK)`) và XML — **không** cùng ngữ nghĩa.

```sql
-- SQL Server: đặt ; trước WITH nếu statement trước trong batch thiếu ;
; WITH cte AS (
    SELECT id FROM orders WHERE status = 'open'
)
SELECT * FROM cte;

-- PostgreSQL: bắt buộc từ khóa RECURSIVE (SQL Server bỏ chữ RECURSIVE)
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
- `WITH` trong XML/JSON trên SQL Server: `WITH XMLNAMESPACES (...)` (khai báo namespace XML) và `OPENJSON(...) WITH (...)` (khai báo schema cột JSON) — [json.md](json.md).
- CTE không phải temp table: tối ưu có thể inline; `MATERIALIZED` / `NOT MATERIALIZED` PostgreSQL (12+) gợi ý.

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

-- PostgreSQL 15+ (WHEN NOT MATCHED BY SOURCE & RETURNING merge_action(): 17+)
MERGE INTO stock AS t
USING staging AS s
ON t.sku = s.sku
WHEN MATCHED THEN
    UPDATE SET qty = s.qty
WHEN NOT MATCHED THEN
    INSERT (sku, qty) VALUES (s.sku, s.qty)
WHEN NOT MATCHED BY SOURCE THEN
    DELETE
RETURNING merge_action(), t.sku;
```

**Ghi chú:**

- Upsert một hàng PG thường `INSERT … ON CONFLICT` rõ hơn `MERGE`. PG 19: `ON CONFLICT DO SELECT` — §17, [dml.md](dml.md).
- SQL Server `MERGE` cần `;` kết thúc. Race: vẫn cần khóa / `HOLDLOCK` cho invariant — [transactions.md](transactions.md).
- PostgreSQL **17+** đã hỗ trợ đầy đủ `WHEN NOT MATCHED BY SOURCE` và `RETURNING merge_action()` (bản PG 15–16 chưa có).
- `MATCHED` trong `MERGE` là nhánh DML, không phải từ khóa graph.

---

## 6. `INSERT` / `UPDATE` / `DELETE` / `TRUNCATE`

```sql
INSERT INTO orders (customer_id, total) VALUES (1, 99.50);
INSERT INTO orders (customer_id, total) SELECT id, 0 FROM customers;

-- SQL Server UPDATE…FROM (non-deterministic nếu một hàng đích khớp nhiều hàng nguồn)
UPDATE o SET o.total = o.total * 1.1
FROM dbo.Orders AS o
JOIN dbo.Customers AS c ON c.Id = o.CustomerId;

-- PostgreSQL UPDATE…FROM (cũng non-deterministic khi nhiều khớp; KHÔNG lặp bảng đích trong FROM)
UPDATE orders o
SET total = total * 1.1
FROM customers c
WHERE c.id = o.customer_id;

DELETE FROM orders WHERE id = 1;
TRUNCATE TABLE orders;                   -- cả hai đều transactional (rollback được); quyền/FK/IDENTITY khác DELETE
```

**Ghi chú:** `TRUNCATE` trên SQL Server **vẫn nằm trong transaction** (rollback được), **không bao giờ** fire `DELETE` trigger, reset `IDENTITY`, yêu cầu quyền `ALTER` và bị chặn nếu có FK trỏ vào; PostgreSQL có `TRUNCATE … CASCADE` / `RESTART IDENTITY` và chỉ fire `TRUNCATE` trigger (không fire `DELETE` trigger). Không port mù. Chi tiết [dml.md](dml.md).


`INSERT … ON CONFLICT DO SELECT` 19: keyword `DO` + `SELECT` sau conflict — không phải statement `SELECT` độc lập.

---

## 7. `RETURNING` / `OUTPUT`

Cùng ý: trả hàng ảnh hưởng. **Không** copy tên clause.

```sql
-- PostgreSQL
INSERT INTO orders (customer_id, total) VALUES (1, 10)
RETURNING id, created_at;

-- PostgreSQL 18+: tham chiếu tường minh OLD / NEW trong RETURNING
UPDATE orders SET total = total + 1 WHERE id = 1
RETURNING OLD.total AS prev_total, NEW.total AS curr_total;

-- SQL Server
INSERT INTO dbo.Orders (CustomerId, Total)
OUTPUT inserted.Id, inserted.CreatedAt
VALUES (1, 10);

DELETE FROM dbo.Orders
OUTPUT deleted.Id
WHERE Id = 1;
```

| Khác biệt | SQL Server `OUTPUT` | PostgreSQL `RETURNING` |
|---|---|---|
| Bảng có trigger | **Lỗi 334** nếu không có `INTO` — bắt buộc `OUTPUT … INTO @t` | Trả trực tiếp bình thường, không cần `INTO` |
| Thời điểm quan sát | Thấy giá trị trước `AFTER`/`INSTEAD OF` trigger (không thấy sửa đổi của trigger) | Thấy hàng **sau** `BEFORE` trigger, trước `AFTER` trigger |
| Giá trị cũ & mới | `deleted.*` / `inserted.*` | **PG 18+**: `OLD.*` / `NEW.*` (trước 18 chỉ thấy giá trị sau `UPDATE`/trước `DELETE`) |

**Ghi chú:**

- `OUTPUT` T-SQL đổ vào bảng/biến bảng: `OUTPUT … INTO @t`; có giới hạn với view/FK/trigger giống nhau không tương đương 1-1 với `RETURNING` — chi tiết [dml.md](dml.md).
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

## 9. `REPACK` (PostgreSQL 19)

Thống nhất `VACUUM FULL` (compact heap) + `CLUSTER` (sort theo index). Lệnh cũ **còn chạy**. Keyword mới, **không** trong transaction block.

```sql
REPACK employees;
REPACK employees USING INDEX employees_pkey;
REPACK (CONCURRENTLY, ANALYZE) employees USING INDEX employees_pkey;
REPACK (VERBOSE) employees;
```

Mặc định `ACCESS EXCLUSIVE` suốt copy. `CONCURRENTLY`: copy dưới `SHARE UPDATE EXCLUSIVE` + logical decoding vào stash; exclusive **lúc swap**. GUC `max_repack_replication_slots`.

`CONCURRENTLY` cấm partitioned, unlogged, catalog/TOAST, và bảng không có PK hoặc replica identity. Snapshot cũ có thể thấy bảng rỗng sau commit. Deadlock lock upgrade lúc swap. Không thay `TRUNCATE`. Chi tiết [ddl.md](ddl.md) §10.1.

SQL Server tương đương gần: `ALTER INDEX … REBUILD` (`ONLINE = ON` historically Enterprise — [internal.md](internal.md) edition). Không logical decoding, không keyword `REPACK`.

**Ghi chú:** Slot + WAL lúc concurrent. Job đêm: thử replica trước. Autovacuum song song **không** thay `REPACK` khi bloat nặng. [ddl.md](ddl.md), [indexes.md](indexes.md). `CLUSTER` keyword cũ ≠ `REPACK` nhưng cùng họ rewrite heap.

`REPACK` unquoted làm tên bảng: contextual — vẫn tránh. `VACUUM` / `ANALYZE` / `VERBOSE` / `CONCURRENTLY` đi cùng.

---

## 10. `BEGIN` / giao dịch / `WAIT FOR`

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
SELECT pg_current_wal_lsn();          -- ví dụ 0/306EE20

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

## 11. DDL: `CREATE` / `ALTER` / `DROP`

```sql
CREATE TABLE t (id int PRIMARY KEY);
ALTER TABLE t ADD COLUMN note text;      -- PG; SQL Server: ADD note nvarchar(100)
DROP TABLE IF EXISTS t;                  -- cả hai (SS 2016+)
```

Nhóm object: `TABLE` `VIEW` `INDEX` `SCHEMA` `DATABASE` `TYPE` `DOMAIN` `SEQUENCE` `FUNCTION` `PROCEDURE` `TRIGGER` `MATERIALIZED VIEW`.

**Ghi chú:** DDL thường có thể rollback trên cả hai engine; ngoại lệ theo lệnh — [ddl.md](ddl.md), [transactions.md](transactions.md). CREATE OR REPLACE (PG) và CREATE OR ALTER (SS) có hạn chế riêng; GO không COMMIT.

`CREATE VECTOR INDEX` SS **PREVIEW** — `VECTOR` contextual. CREATE JSON INDEX GA. `CREATE EXTERNAL MODEL` — AI, không keyword graph.


---

## 12. Constraint

`CONSTRAINT` `PRIMARY` `FOREIGN` `UNIQUE` `CHECK` `REFERENCES` `DEFAULT` `NOT NULL` `DEFERRABLE` (PG) `EXCLUDE` (PG) `ENFORCED` (PG **19** CHECK).

```sql
CREATE TABLE t (
    id int PRIMARY KEY,
    email text NOT NULL UNIQUE,
    parent_id int REFERENCES t (id),
    CHECK (id > 0)
);
```

**Ghi chú:** `DEFAULT` vừa keyword constraint vừa `DEFAULT VALUES` lúc insert. `PRIMARY` không dùng làm tên cột unquoted. Deferred: chỉ PostgreSQL — [constraints.md](constraints.md). `WITHOUT OVERLAPS` 18+ đi với PK temporal.

PG 19: `ALTER … CONSTRAINT … [NOT] ENFORCED` trên **CHECK**. Khác `NOT VALID`.

---

## 13. Window: `OVER` / `FILTER` / `IGNORE NULLS`

```sql
SELECT SUM(total) OVER (PARTITION BY customer_id ORDER BY id) AS running
FROM orders;

-- PostgreSQL
SELECT SUM(total) FILTER (WHERE status = 'paid') FROM orders;
SELECT LAG(value) IGNORE NULLS OVER (ORDER BY ts) FROM metrics;   -- PG 19
SELECT LAST_VALUE(value) RESPECT NULLS OVER (
    ORDER BY ts
    ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
)
FROM metrics;
```

Hàm 19: `lead`, `lag`, `first_value`, `last_value`, `nth_value`. Mặc định `RESPECT NULLS`.

**Ghi chú:** `FILTER` aggregate: PG; SQL Server dùng `SUM(CASE WHEN …)`. `GROUPS` frame: PG. `IGNORE NULLS` **không** phải toán tử, không dùng trong `WHERE` — [operators.md](operators.md), [window-functions.md](window-functions.md). Frame `LAST_VALUE` mặc định đến `CURRENT ROW` — `IGNORE NULLS` không sửa frame sai. SQL Server **2022+** hỗ trợ `IGNORE NULLS` trên `FIRST_VALUE`, `LAST_VALUE`, `LAG`, `LEAD` (không có `NTH_VALUE`). `PIVOT`/`UNPIVOT`: chỉ SQL Server (keyword). `WINDOW` clause đặt tên frame.

---

## 14. Điều khiển luồng

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
    IF @i = 5 CONTINUE;
    IF @i = 8 BREAK;
END
```

```sql
-- PostgreSQL: IF/LOOP chỉ trong hàm/DO (PL/pgSQL), không phải SQL thường
DO $$
DECLARE
    x int := 1;
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

## 15. `GRANT` / `REVOKE` / `DENY`

`DENY` chỉ SQL Server (thắng `GRANT` trừ sysadmin). PG: `GRANT`/`REVOKE`, không `DENY`.

```sql
-- SQL Server
GRANT SELECT ON dbo.Orders TO app;
DENY DELETE ON dbo.Orders TO app;

-- PostgreSQL
GRANT SELECT ON app.orders TO app;
REVOKE INSERT ON app.orders FROM app;
ALTER TABLE app.orders OWNER TO app_owner;
```

`AUTHORIZATION` lúc `CREATE SCHEMA`. Principal, `PUBLIC`, schema, RLS, ownership: [permissions.md](permissions.md). `SECURITY DEFINER` / `EXECUTE AS`: [routines.md](routines.md) + `search_path`.

PG 19: `GRANT`/`REVOKE … GRANTED BY` — role hiệu lực khi ghi ACL. SQL Server 2025: Purview policies discontinued → role `##MS_*##` — [internal.md](internal.md), không keyword SQL mới trong file này.

---

## 16. SQL Server 2025 — built-in mới

Không đợt reserved word lớn; thêm **type / hàm / config**. Tên có thể đụng cột cũ.

| Tên | Vai trò | Ghi chú |
|---|---|---|
| `VECTOR` / `vector(n)` | Kiểu | Quote cột tên `vector` nếu đụng |
| `VECTOR_DISTANCE` / `VECTOR_NORM` / `VECTOR_NORMALIZE` / `VECTORPROPERTY` | Hàm | **GA** |
| `VECTOR_SEARCH` / `CREATE VECTOR INDEX` | ANN | **PREVIEW** + `PREVIEW_FEATURES` |
| `AI_GENERATE_EMBEDDINGS` / `AI_GENERATE_CHUNKS` | Hàm | Model REST; credential tách |
| `JSON_OBJECTAGG` / `JSON_ARRAYAGG` | Aggregate | **2025 GA** |
| `JSON_CONTAINS` / `CREATE JSON INDEX` | JSON | **GA** — [operators.md](operators.md) |
| `REGEXP_LIKE` … | Regex | **GA** |
| `CURRENT_DATE` | Hàm `date` | **2025** — đụng cột cùng tên |
| `UNISTR` / `PRODUCT` | Hàm | **2025** |
| `BASE64_ENCODE` / `BASE64_DECODE` | Hàm | Không literal — [literals.md](literals.md) |
| `PREVIEW_FEATURES` | Database scoped | Bật preview |
| `CREATE EXTERNAL MODEL` | AI | Credential, không hard-code |
| `SUBSTRING` length optional / `DATEADD` bigint | Hàm | **2025** |

Fuzzy `EDIT_DISTANCE*` / `JARO_WINKLER*`: **GA từ CU11** (12/11/2026). CES / vector index / `VECTOR_SEARCH` / half-precision: vẫn **PREVIEW**. CES và mirroring: kiến trúc log — [internal.md](internal.md), [concurrency.md](concurrency.md).

`CURRENT_DATE` không phải literal — [typesystem.md](typesystem.md) §4.4, [literals.md](literals.md).

---

## 17. PostgreSQL 19 — clause mới

| Keyword / clause | Mục đích | Ghi chú |
|---|---|---|
| `REPACK` [`CONCURRENTLY`] | Rebuild bảng/index | Không trong txn; `CONCURRENTLY` không MVCC-safe |
| `WAIT` `FOR` | Chờ LSN standby | ≠ `WAITFOR` T-SQL |
| `IGNORE NULLS` / `RESPECT NULLS` | Window | Không `WHERE` |
| `DO SELECT` | `ON CONFLICT DO SELECT` | Khóa hàng đã có; **19** |
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

## 18. Hay đụng identifier

Tránh unquoted (cột/bảng/schema). Quote được nhưng ORM và SQL động khổ.

`order`, `user`, `group`, `table`, `index`, `key`, `value`, `type`, `name`, `date`, `time`, `level`, `offset`, `window`, `rank`, `left`, `right`, `inner`, `check`, `default`, `constraint`, `primary`, `references`, `session_user`, `current_user`, `current_date`, `current_timestamp`, `json`, `xml`, `vector`, `end`, `file`, `plan`, `limit`, `both`, `all`, `any`, `some`, `role`, `grant`, `match`, `filter`, `over`, `range`, `rows`, `lead`, `lag`, `first`, `next`, `percent`, `ties`, `output`, `merge`, `apply`, `pivot`, `identity`, `national`, `zone`, `precision`, `interval`, `cascade`, `restrict`, `replace`, `return`, `language`, `external`, `cursor`, `fetch`, `deallocate`, `declare`, `execute`, `backup`, `restore`, `waitfor`, `partition`, `clusters`/`cluster`, `analyse`/`analyze`, `verbose`, `freeze`, `repack`, `columns`, `wait`.

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


---

## 19. Hai session — ví dụ làm việc

### 19.1 `BEGIN` port

```text
T1 (SS): BEGIN SELECT 1; END;            -- khối, auto-commit mặc định
T2 (PG): BEGIN; SELECT 1;                -- txn mở, T2 giữ lock/xmin đến COMMIT
-- Pool PG: idle in transaction — [internal.md](internal.md)
```

### 19.2 `WAITFOR` vs `WAIT FOR`

```text
T1 (SS): WAITFOR DELAY '00:00:01'; SELECT * FROM dbo.Orders WHERE Id = 42;
         -- chỉ ngủ, không đợi replica
T2 (PG standby): WAIT FOR LSN '…' WITH (MODE 'standby_replay'); SELECT …
         -- đúng LSN mới thấy commit primary
```

### 19.3 `CURRENT_DATE` đụng cột

```text
T1 (SS 2022): SELECT current_date FROM dbo.T;       -- cột
T2 (SS 2025): SELECT current_date FROM dbo.T;       -- HÀM date (reserved keyword), không phải cột
              SELECT t.current_date FROM dbo.T AS t; -- vẫn lỗi syntax trên SS 2025!
-- Sửa: SELECT t.[current_date] FROM dbo.T AS t;  hoặc đổi tên cột
```

### 19.4 `DO SELECT` vs `DO UPDATE`

```text
T1: INSERT … ON CONFLICT (id) DO UPDATE SET val = EXCLUDED.val;
    -- ghi đè
T2: INSERT … ON CONFLICT (id) DO SELECT FOR UPDATE RETURNING *;
    -- không ghi, trả + khóa hàng cũ
```

### 19.5 `VECTOR` identifier vs type

```text
T1: CREATE TABLE dbo.Vector (Id int);           -- tên bảng
T2: CREATE TABLE dbo.Doc (Embedding vector(3)); -- kiểu 2025
    SELECT vector FROM dbo.Something;           -- cột vs kiểu — quote nếu cần
```

---

## 20. Best practices & checklist

- Đặt tên nghiệp vụ (`app_user`, `sort_order`) thay vì quote reserved.
- Schema-qualify; đừng `user` làm bảng rồi `SET search_path`.
- `;` trước `WITH` CTE trên T-SQL.
- `BEGIN TRAN` vs `BEGIN` — đọc dialect trước khi review txn.
- `OUTPUT`/`RETURNING`, `TOP`/`LIMIT`, `APPLY`/`LATERAL` ghi rõ khi port.
- `MERGE`: test race; cân nhắc `ON CONFLICT` (PG); 19 `DO SELECT` khi chỉ cần hàng cũ.
- `CURRENT_DATE` / `VECTOR` / `JSON`: soi cột cũ trước nâng 2025.
- Tra `pg_get_keywords` khi đặt tên mới trên PG.

---

## 21. Bẫy khi review

- `BEGIN` T-SQL như mở txn.
- `WITH (NOLOCK)` bị đọc thành CTE.
- `FETCH` cursor vs `OFFSET FETCH`.
- `WAITFOR` vs `WAIT FOR`.
- `MERGE` SQL Server copy lên PG: PG **17+** đã có `WHEN NOT MATCHED BY SOURCE` và `RETURNING merge_action()`, nhưng vẫn lệch ở `OUTPUT`/`$action`, isolation/race và PG < 17.
- `UPDATE … FROM` fan-out (non-deterministic trên cả hai engine; PG thêm bẫy lặp bảng đích trong `FROM`).
- `SELECT user` tưởng cột.
- `SELECT current_date` hoặc `SELECT t.current_date` sau khi nâng SQL 2025 — phải quote `t.[current_date]`.
- `FILTER` / `IGNORE NULLS` giả có trên mọi hàm SQL Server (`IGNORE NULLS` SS 2022+ không có `NTH_VALUE`).
- `NATURAL JOIN` / tên cột `date` thêm vào bảng làm join đổi.
- `GO` trong keyword list — không phải T-SQL.
- `TRUNCATE` như `DELETE` (trigger, identity, FK).
- `DENY` port sang PG.
- `REPACK` trong `BEGIN` block.
- `DO SELECT` tưởng `DO UPDATE`.
- `MATCH` MERGE vs `MATCH` PGQ vs SQL Graph SS.
- `VECTOR_SEARCH` prod không `PREVIEW_FEATURES`.
- Port `REPACK` → `REORGANIZE` (không cùng) — [internal.md](internal.md).

---

## 22. Version gates

| Mục | SQL Server | PostgreSQL |
|---|---|---|
| `CREATE OR ALTER` | 2016 SP1+ | `CREATE OR REPLACE` lâu |
| `DROP IF EXISTS` | 2016+ | lõi |
| `MERGE` | lâu (cẩn thận) | **15+** (`BY SOURCE` / `merge_action()`: **17+**) |
| `ON CONFLICT` | — (`MERGE`/hint) | **9.5+**; `DO SELECT` **19** |
| `OFFSET FETCH` | 2012+ | lâu |
| `IS DISTINCT FROM` | **2022+** | lõi |
| `JSON_OBJECTAGG` | **2025 GA** | **16+** (cũ: `json_object_agg`) |
| `REGEXP_LIKE` | **2025** | **15+** (`~` lâu) |
| `CURRENT_DATE` | **2025** | lõi |
| `VECTOR` type | **2025 GA** | pgvector ext |
| `VECTOR_SEARCH` | **2025 PREVIEW** | — |
| `UNISTR` / `PRODUCT` | **2025** | — / thủ công |
| `REPACK` | rebuild index | **19** |
| `WAIT FOR` LSN | — (`WAITFOR` khác) | **19** |
| `IGNORE NULLS` window | **2022+** | **19** |
| `RETURNING OLD` / `NEW` | `deleted` / `inserted` (`OUTPUT`) | **18+** |
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
| `WAIT` | — | `WAIT FOR` (hai token, PG **19**) |
| `WAITFOR` | T-SQL delay | không có trên PG |
| `DO` | `DO $$` PL block | `DO UPDATE` / `DO NOTHING` / `DO SELECT` |
| `VECTOR` | Kiểu / hàm SS **2025** | Tên cột/bảng |
| `CURRENT_DATE` | Hàm (SS **2025**, PG lõi) | Tên cột |
| `JSON` | Kiểu SS **GA** / PG | Tên cột |
| `FILTER` | Aggregate PG | Tên cột; không T-SQL aggregate |
| `OVER` | Window | Tên cột |

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

Không `OUTPUT`. Không T-SQL. **PostgreSQL 19 (GA)**. Unique index bắt buộc. [dml.md](dml.md).

`FOR UPDATE` đây là lock clause của `DO SELECT`, không phải `WAIT FOR`.

---

## Phụ lục C. `REPACK` vs `VACUUM` vs `CLUSTER` — token

```sql
VACUUM (FULL, ANALYZE) employees;        -- cũ, còn chạy
CLUSTER employees USING employees_pkey;  -- cũ, còn chạy
REPACK (CONCURRENTLY, ANALYZE) employees USING INDEX employees_pkey;  -- 19
```

Cả ba *rewrite/sắp heap* theo nghĩa vận hành, **ba keyword**. Job cron `CLUSTER` không tự thành `REPACK (CONCURRENTLY)`. `VACUUM` không `CONCURRENTLY` kiểu index. `REPACK` cấm transaction block — `BEGIN; REPACK …` lỗi.

SQL Server: không token này. `ALTER INDEX … REBUILD` / `REORGANIZE` — edition `ONLINE` — [internal.md](internal.md).

---

## Nguồn chính thức

Đối chiếu ngày **21/11/2026**. PostgreSQL **19** GA **19/11/2026**. SQL Server 2025 **CU11** (12/11/2026): fuzzy GA; vector index, `VECTOR_SEARCH`, half-precision và CES vẫn PREVIEW. Xem [baseline và quy ước ví dụ](README.md#trạng-thái-phiên-bản-và-cách-kiểm-chứng).

- [PostgreSQL SELECT grammar](https://www.postgresql.org/docs/19/sql-select.html)
- [PostgreSQL INSERT grammar](https://www.postgresql.org/docs/19/sql-insert.html)
- [SQL Server 2025 language features](https://learn.microsoft.com/en-us/sql/sql-server/what-s-new-in-sql-server-2025?view=sql-server-ver17)
