# DDL (CREATE / ALTER / DROP)

> **Baseline:** SQL Server **2025** (17.x) · PostgreSQL **19 Beta 4**.<br>
> DDL thường dùng có thể rollback trên cả SQL Server và PostgreSQL. Ngoại lệ phụ thuộc từng lệnh; GO chỉ tách batch, không COMMIT. Kiểm tra lock, log, edition và giới hạn transaction của tác vụ bảo trì.

DDL lấy **schema lock** mạnh: chặn DML, xếp hàng sau transaction dài. Production: thao tác metadata-only / `NOT VALID` / `ONLINE` / `CONCURRENTLY`, không `ALTER` rewrite bảng lớn trong giờ cao điểm. Partition `SPLIT`/`MERGE` (PG **19**, **beta**) và `REPACK` không phải lệnh “rẻ mặc định”.

Constraint: [constraints.md](constraints.md). Index: [indexes.md](indexes.md). Khóa AccessExclusive: [concurrency.md](concurrency.md). Trạng thái SQL/PGQ: [select.md](select.md) §11. Isolation khi DDL trong txn: [transactions.md](transactions.md) §10. Vacuum vs rebuild: [internal.md](internal.md) §11.

---

## Mục lục

- [1. Tổng quan & triết lý](#1-tổng-quan--triết-lý)
- [2. Transactional DDL và các ngoại lệ](#2-transactional-ddl-và-các-ngoại-lệ)
- [3. Database & schema](#3-database--schema)
- [4. TABLE](#4-table)
- [5. ALTER không chặn](#5-alter-không-chặn)
- [6. Generated: virtual vs persisted](#6-generated-virtual-vs-persisted)
  - [6.1 Extended stats trên VIRTUAL (PG 19)](#61-extended-stats-trên-virtual-pg-19)
- [7. Partition SPLIT / MERGE](#7-partition-split--merge)
  - [7.1 PostgreSQL — declarative partitioning](#71-postgresql--declarative-partitioning)
  - [7.2 SQL Server — function / scheme / SWITCH](#72-sql-server--function--scheme--switch)
- [8. VIEW, indexed view, matview](#8-view-indexed-view-matview)
- [9. SEQUENCE & replication (PG 19)](#9-sequence--replication-pg-19)
  - [9.1 ALL SEQUENCES / REFRESH SEQUENCES](#91-all-sequences--refresh-sequences)
- [10. REPACK vs REBUILD](#10-repack-vs-rebuild)
  - [10.1 REPACK CONCURRENTLY](#101-repack-concurrently)
- [11. Property graph — đã rút khỏi PostgreSQL 19](#11-property-graph--đã-rút-khỏi-postgresql-19)
- [12. IF EXISTS / CASCADE](#12-if-exists--cascade)
- [13. Worked examples](#13-worked-examples)
  - [13.1 Đơn giản — bảng + identity trong txn (PG) vs batch (SS)](#131-đơn-giản--bảng--identity-trong-txn-pg-vs-batch-ss)
  - [13.2 Trung bình — VIRTUAL + extended stats + index online](#132-trung-bình--virtual--extended-stats--index-online)
  - [13.3 Thêm partition, đồng bộ sequence và REPACK](#133-thêm-partition-đồng-bộ-sequence-và-repack)
  - [13.4 Rollback ALTER TABLE trên cả hai engine](#134-rollback-alter-table-trên-cả-hai-engine)
  - [13.5 VALIDATE vs NOCHECK](#135-validate-vs-nocheck)
- [14. Best practices & checklist](#14-best-practices--checklist)
- [15. Bẫy khi review](#15-bẫy-khi-review)
- [16. Version gates](#16-version-gates)
- [Nguồn chính thức](#nguồn-chính-thức)

---

## 1. Tổng quan & triết lý

Schema là API: đổi cột, view `SELECT *`, sequence, graph metadata đều có caller. DDL “chạy nhanh trên staging rỗng” không dự đoán lock trên production.

Ba câu hỏi trước mỗi `ALTER`:

1. **Rewrite bảng hay metadata?** (đổi kiểu / `STORED` generated vs add nullable).
2. **Lock gì, giữ bao lâu?** (`ACCESS EXCLUSIVE` vs `SHARE UPDATE EXCLUSIVE` + validate).
3. **Rollback được không?** (cả hai có transactional DDL, ngoại lệ từng lệnh).

PostgreSQL 19 Beta 4: REPACK, sequence trong logical replication và extended stats trên virtual generated còn hỗ trợ; SQL/PGQ và SPLIT/MERGE partition đã bị rút — đối chiếu [release notes 19](https://www.postgresql.org/docs/19/release-19.html). SQL Server 2025: compatibility **170**, `PREVIEW_FEATURES` (vector index, CES, fuzzy) — [internal.md](internal.md) §19.

---

## 2. Transactional DDL và các ngoại lệ

Cả SQL Server và PostgreSQL đều cho rollback nhiều DDL thường dùng, gồm `CREATE TABLE`, `ALTER TABLE` và tạo index thường. SQL Server không tự commit DML trước đó chỉ vì chạy các lệnh này. Khóa schema và lượng log vẫn có thể khiến rollback chậm.

```sql
-- SQL Server: GO tách batch, không tự COMMIT transaction.
BEGIN TRAN;
CREATE TABLE #ddl_demo (id int PRIMARY KEY);
INSERT INTO #ddl_demo VALUES (1);
ALTER TABLE #ddl_demo ADD note nvarchar(100);
CREATE INDEX ix_ddl_demo ON #ddl_demo (note);
ROLLBACK TRAN;
SELECT OBJECT_ID(N'tempdb..#ddl_demo') AS object_after_rollback; -- NULL
```

```sql
-- PostgreSQL
BEGIN;
CREATE TEMP TABLE ddl_demo (id int PRIMARY KEY);
INSERT INTO ddl_demo VALUES (1);
ALTER TABLE ddl_demo ADD COLUMN note text;
CREATE INDEX ix_ddl_demo ON ddl_demo (note);
ROLLBACK;
SELECT to_regclass('pg_temp.ddl_demo'); -- NULL
```

| Ngoại lệ | SQL Server | PostgreSQL |
|---|---|---|
| Database | `CREATE/DROP DATABASE` không trong user transaction | `CREATE/DROP DATABASE` không trong transaction block |
| Index | `RESUMABLE = ON` không trong explicit transaction; `ONLINE` tự nó không có nghĩa này | `CREATE/DROP INDEX CONCURRENTLY`, `REINDEX CONCURRENTLY` ngoài transaction block |
| Bảo trì | `TRUNCATE` và rebuild thông thường có thể rollback; xem hạn chế từng lệnh | `VACUUM`, `REPACK` ngoài transaction block |
| Materialized view | Indexed view có quy tắc riêng | `REFRESH MATERIALIZED VIEW CONCURRENTLY` có thể chạy trong transaction |
| Batch | `GO` không commit; giữ cùng connection để giữ transaction | `psql` gửi statement theo terminator |

Sau `ALTER TYPE ... ADD VALUE` trong transaction PostgreSQL hiện đại, giá trị enum mới chỉ dùng được sau commit. Đây là hạn chế về sử dụng giá trị mới, khác việc cấm DDL trong transaction.

Migration cần phân biệt **lệnh không cho mở transaction**, **lệnh rollback được nhưng tốn log/giữ khóa**, và **tool tự commit từng bước**. Dùng `TRY/CATCH` + `XACT_STATE()` trên SQL Server để rollback khi lỗi. Xem [CREATE INDEX](https://learn.microsoft.com/en-us/sql/t-sql/statements/create-index-transact-sql?view=sql-server-ver17), [BEGIN TRANSACTION](https://learn.microsoft.com/en-us/sql/t-sql/language-elements/begin-transaction-transact-sql?view=sql-server-ver17) và [REFRESH MATERIALIZED VIEW](https://www.postgresql.org/docs/19/sql-refreshmaterializedview.html).

---

## 3. Database & schema

```sql
-- SQL Server
CREATE DATABASE Sales;
ALTER DATABASE Sales SET COMPATIBILITY_LEVEL = 170;   -- 2025
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;  -- chỉ khi chấp nhận CU đổi
CREATE SCHEMA app AUTHORIZATION dbo;

-- PostgreSQL
CREATE DATABASE sales;
-- \c sales
CREATE SCHEMA app AUTHORIZATION app_owner;
```

Collation / encoding **lúc tạo DB**. Đổi collation SQL Server: phức tạp (rebuild). PostgreSQL: encoding cluster; collation cột ICU được. `CREATE DATABASE` không nằm gọn trong txn ứng dụng.

SQL Server object: `server.database.schema.object`. PostgreSQL: không `SELECT` cross-database trong một statement (FDW / dblink) — [dialects.md](dialects.md).

Compat **170** đổi IQP mặc định (DOP, QS secondary) — [select.md](select.md) §14. Nâng engine ≠ nâng compat.

**Ghi chú:** `PREVIEW_FEATURES` production = chấp nhận breaking giữa CU (vector index, CES, fuzzy kéo theo **cả database**). PG 19: `standard_conforming_strings` luôn on; tên DB/role/tablespace không CR/LF — `pg_upgrade` từ chối. [internal.md](internal.md) §16, §19.

---

## 4. TABLE

```sql
CREATE TABLE orders (
    id          int GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,  -- PG
    -- id       int IDENTITY(1,1) PRIMARY KEY,                     -- SQL Server
    customer_id int NOT NULL REFERENCES customers (id),
    total       numeric(12,2) NOT NULL CHECK (total >= 0),
    status      text NOT NULL DEFAULT 'new',
    created_at  timestamptz NOT NULL DEFAULT now()
);
```

```sql
-- SQL Server: heap vs clustered
CREATE TABLE dbo.Orders (
    Id         int IDENTITY(1,1) NOT NULL PRIMARY KEY CLUSTERED,
    CustomerId int NOT NULL,
    Total      decimal(12,2) NOT NULL
);

-- Memory-optimized / columnstore: tùy workload, không mặc định OLTP hẹp
```

Temporary:

```sql
-- SQL Server
CREATE TABLE #tmp (id int);          -- session
CREATE TABLE ##global (id int);      -- instance, tên global

-- PostgreSQL
CREATE TEMP TABLE tmp (id int) ON COMMIT DROP;
CREATE TEMP TABLE tmp (id int) ON COMMIT PRESERVE ROWS;
```

`UNLOGGED` (PG): mất sau crash, nhanh hơn — staging [dml.md](dml.md) bulk. SQL Server không có `UNLOGGED`; heap + minimal log gần về ý. `REPACK` trên unlogged: hạn chế 19 (mục 10).

PK clustered (SS) = thứ tự trang. PostgreSQL heap mặc định; `CLUSTER`/`REPACK … USING INDEX` sắp **một lần**, không duy trì — [indexes.md](indexes.md).

`fillfactor` (PG) / `FILLFACTOR` (SS) lúc `CREATE TABLE`/`INDEX`: chừa chỗ update in-place (SS) hoặc giảm page split; PG update vẫn tuple mới — fillfactor chủ yếu insert/HOT. Đổi fillfactor trên bảng lớn = rewrite/`REPACK`/`REBUILD`, không metadata-only.

```sql
-- PostgreSQL
CREATE TABLE events (…) WITH (fillfactor = 90);
ALTER TABLE events SET (fillfactor = 90);   -- hàng mới; REPACK để áp heap cũ

-- SQL Server
CREATE INDEX ix ON dbo.Orders (CustomerId) WITH (FILLFACTOR = 90);
```

**Ghi chú:** `CREATE TABLE AS SELECT` / `SELECT INTO` (SS) copy dữ liệu, **không** copy index/constraint đủ bộ. Partitioned: PK phải gồm khóa partition (PG declarative) — mục 7.

---

## 5. ALTER không chặn

Mục tiêu production: tránh rewrite + tránh `ACCESS EXCLUSIVE` dài.

```sql
ALTER TABLE orders ADD COLUMN note text;
ALTER TABLE orders DROP COLUMN note;
ALTER TABLE orders ALTER COLUMN total TYPE numeric(14,2);   -- PG; có thể rewrite
ALTER TABLE dbo.Orders ALTER COLUMN Total decimal(14,2);    -- SQL Server
```

| Thao tác | SQL Server | PostgreSQL |
|---|---|---|
| Add cột **nullable**, không default volatile | Metadata, nhanh | Metadata |
| Add cột + **constant** default | Bản gần: metadata | PG 11+: không rewrite |
| Add cột + `DEFAULT` volatile (`now()`) | Có thể điền / lock | Rewrite hoặc fill |
| Đổi kiểu binary compatible | Ít đau | Ít đau (`varchar(10)`→`varchar(20)`) |
| Đổi kiểu không tương thích | Rewrite | Rewrite bảng |
| Add FK / CHECK | Scan + lock | `NOT VALID` rồi `VALIDATE CONSTRAINT` |
| `SET NOT NULL` | Scan | Scan; có thể dựa CHECK đã valid (bản gần) |
| Add index | `ONLINE = ON` (edition) | `CREATE INDEX CONCURRENTLY` (ngoài txn) |

```sql
-- PostgreSQL: FK hai bước — ADD nhanh, VALIDATE scan SHARE UPDATE EXCLUSIVE
ALTER TABLE orders
    ADD CONSTRAINT orders_customer_fk
    FOREIGN KEY (customer_id) REFERENCES customers (id) NOT VALID;

ALTER TABLE orders VALIDATE CONSTRAINT orders_customer_fk;
```

`NOT VALID` vẫn kiểm tra **hàng mới**; hàng cũ validate sau. CHECK tương tự — [constraints.md](constraints.md). PG 19: `ALTER … CONSTRAINT … [NOT] ENFORCED` cho **CHECK** (trước chỉ FK).

SQL Server: `WITH CHECK CHECK CONSTRAINT` vs `NOCHECK` — `NOCHECK` **không** tương đương `NOT VALID` (hàng mới cũng có thể không kiểm nếu disable). Đừng disable FK lâu trên OLTP.

Đổi tên cột / `DROP COLUMN`: view, proc, client bind vỡ. PG `DROP COLUMN` nhanh (metadata); disk thu hồi sau rewrite/`REPACK`. SS: cột lớn + compression — đo.

**Ghi chú:** `ALTER TYPE` enum `ADD VALUE` (PG) từng không transaction-safe. Session khác cache plan / prepared statement: SS đổi schema → recompile; PG: `DISCARD PLANS` hiếm khi cần nếu search_path ổn. `CREATE SCHEMA` 19 được tạo thêm loại object trong schema mới; **không** reorder (FK vẫn cuối).

---

## 6. Generated: virtual vs persisted

```sql
-- SQL Server computed
ALTER TABLE dbo.Invoice ADD
    Total AS (Qty * Price) PERSISTED;

-- Không PERSISTED: tính lúc đọc (và một số plan)
ALTER TABLE dbo.Invoice ADD
    Total AS (Qty * Price);
```

```sql
-- PostgreSQL 18+: VIRTUAL = tính lúc đọc (mặc định generated mới)
ALTER TABLE invoice
    ADD COLUMN total numeric GENERATED ALWAYS AS (qty * price) VIRTUAL;

-- STORED = ghi lúc INSERT/UPDATE (như persisted)
ALTER TABLE invoice
    ADD COLUMN total numeric GENERATED ALWAYS AS (qty * price) STORED;
```

Index:

- SQL Server: index trên computed cần **PERSISTED**, deterministic, session `SET` (ANSI_NULLS, QUOTED_IDENTIFIER, …) đúng — indexed view cùng luật.
- PostgreSQL: index cột `STORED`; hoặc **expression index** trên biểu thức / cột `VIRTUAL`.

`GENERATED ALWAYS AS IDENTITY` (mục 4, [dml.md](dml.md)) khác generated **cột tính**: identity là sequence, không phải `(qty * price)`.

SQL Server system-versioned: `GENERATED ALWAYS AS ROW START/END` — temporal **system-time**, không virtual business column.

### 6.1 Extended stats trên VIRTUAL (PG 19)

Trước 19: `CREATE STATISTICS` trên cột `VIRTUAL` / biểu thức generated không lưu — planner thiếu MCV/histogram tương quan cho cặp `(virtual_col, other)`.

PostgreSQL **19**: extended stats trên **virtual generated**. Dump/restore 19 giữ extended stats. Hàm:

```sql
CREATE STATISTICS st_invoice_total (dependencies)
    ON total, customer_id FROM invoice;   -- total là VIRTUAL 19: được

SELECT pg_clear_extended_stats('public', 'invoice', 'public', 'st_invoice_total', false); -- 19; object phải tồn tại
-- pg_restore_extended_stats(): restore từ dump — đối chiếu docs 19
```

`ANALYZE` sau khi tạo stats. Không thay expression index khi predicate *seek* theo `total`; stats chỉ giúp **CE** join/filter.

Các kind extended stats (cả trước 19, 19 thêm virtual):

```sql
CREATE STATISTICS st_ord (dependencies, ndistinct, mcv)
    ON customer_id, status, country FROM orders;
ANALYZE orders;
```

- `dependencies`: tương quan cột (country → city).
- `ndistinct`: số giá trị phân biệt nhóm.
- `mcv`: most common values tổ hợp.

Virtual generated trong danh sách `ON` **19**: planner thấy CE cho `total` × `customer_id` mà không cần `STORED`. `pg_clear_extended_stats(schema, table, stats_schema, stats_name, inherited)` xóa dữ liệu của một object extended statistics — dùng trước dump lạ / sau đổi generated expression. `pg_restore_extended_stats()`: restore từ dump 19 — đối chiếu signature docs, không bịa tham số.

SQL Server: `CREATE STATISTICS` / auto stats; 2025 persist trên secondary. Không port tên `dependencies`/`mcv`.

**Ghi chú:** Đổi biểu thức generated = rewrite (`STORED`/`PERSISTED`) hoặc chỉ metadata (`VIRTUAL`) tùy engine/phiên bản — test `EXPLAIN` / size. Không `UPDATE` trực tiếp cột `GENERATED ALWAYS` (trừ `OVERRIDING` cho identity). Xóa stats trước `DROP COLUMN` generated nếu dump kêu ca — `pg_clear_extended_stats` 19.

---

## 7. Partition SPLIT / MERGE

### 7.1 PostgreSQL — declarative partitioning

```sql
CREATE TABLE events (
    id bigint NOT NULL,
    ts timestamptz NOT NULL,
    PRIMARY KEY (id, ts)
) PARTITION BY RANGE (ts);

CREATE TABLE events_2026_09 PARTITION OF events
    FOR VALUES FROM ('2026-09-01 00:00:00+00') TO ('2026-10-01 00:00:00+00');
```

PK/UNIQUE của bảng partitioned phải chứa mọi cột khóa partition (và khóa partition không được là biểu thức đối với ràng buộc đó). Dùng mốc có timezone rõ ràng với `timestamptz`.

**SPLIT/MERGE partition đã bị rút khỏi PostgreSQL 19 Beta 4**, xem [thông báo Beta 4](https://www.postgresql.org/about/news/postgresql-19-beta-4-released-3386/). Để đổi biên partition hiện tại: tạo bảng staging với biên mới, chuyển dữ liệu và dùng `DETACH/ATTACH PARTITION` với kế hoạch khóa/cutover cụ thể. `DETACH PARTITION CONCURRENTLY` có hạn chế riêng, gồm việc không chạy trong transaction block. Đừng xóa partition cũ trước khi kiểm tra số hàng và biên của dữ liệu mới.

---

### 7.2 SQL Server — function / scheme / SWITCH

```sql
CREATE PARTITION FUNCTION PF_Date (date)
    AS RANGE RIGHT FOR VALUES ('2026-01-01', '2026-07-01');

CREATE PARTITION SCHEME PS_Date
    AS PARTITION PF_Date TO ([FG1], [FG2], [FG3]);

CREATE TABLE dbo.Events (
    Id bigint NOT NULL,
    Ts date NOT NULL,
    CONSTRAINT PK_Events PRIMARY KEY CLUSTERED (Ts, Id)
) ON PS_Date (Ts);
```

```sql
ALTER PARTITION SCHEME PS_Date NEXT USED [FG4];
ALTER PARTITION FUNCTION PF_Date() SPLIT RANGE ('2026-10-01');

ALTER PARTITION FUNCTION PF_Date() MERGE RANGE ('2026-07-01');

ALTER TABLE dbo.Events SWITCH PARTITION 2 TO dbo.Events_Staging;
```

`SPLIT`/`MERGE` trên **function** ảnh hưởng **mọi** bảng dùng scheme. Filegroup trống (`NEXT USED`) **trước** `SPLIT` — thiếu = lỗi. `SWITCH` đòi aligned index, check constraint khớp biên, không FK lệch.

`RANGE RIGHT` vs `LEFT`: giá trị biên thuộc partition nào — sai một ngày = dữ liệu “sai ngăn”, `SWITCH` fail.

**Ghi chú:** Đừng copy `ALTER TABLE … SPLIT PARTITION` PG sang T-SQL (SS tách function/scheme). PG 19 Beta 4 không hỗ trợ SPLIT/MERGE partition. Unique aligned SS vs PK gồm partition-key PG. `SWITCH` ≈ `DETACH`+gắn staging, không phải `TRUNCATE`.

---

## 8. VIEW, indexed view, matview

```sql
CREATE VIEW v_paid AS
SELECT id, customer_id, total, status
FROM orders
WHERE status = 'paid';
```

`SELECT *` bind **lúc CREATE**: thêm cột bảng gốc **không** xuất hiện đến `CREATE OR REPLACE` / `sp_refreshview`. Cả hai engine.

```sql
-- PostgreSQL matview
CREATE MATERIALIZED VIEW mv_daily AS
SELECT date_trunc('day', created_at) AS d, SUM(total) AS s
FROM orders
GROUP BY 1
WITH NO DATA;

CREATE UNIQUE INDEX mv_daily_d ON mv_daily (d);
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_daily;   -- cần unique index
```

`REFRESH` không `CONCURRENTLY`: khóa đọc. `CONCURRENTLY`: cho phép đọc, cần unique, **không trong txn block**.

```sql
-- SQL Server indexed view (không có CREATE MATERIALIZED VIEW)
CREATE VIEW dbo.v_daily
WITH SCHEMABINDING
AS
SELECT
    CONVERT(date, o.CreatedAt) AS d,
    COUNT_BIG(*) AS cnt,
    SUM(o.Total) AS s
FROM dbo.Orders AS o
GROUP BY CONVERT(date, o.CreatedAt);
GO
CREATE UNIQUE CLUSTERED INDEX ix_v_daily ON dbo.v_daily (d);
```

Indexed view: `SCHEMABINDING`, `COUNT_BIG`, `SET` options, deterministic. Query optimizer dùng index nếu `NOEXPAND` / edition / CE. Không phải bản sao `REFRESH` tay như matview — bảo trì lúc DML (đắt trên OLTP ghi nhiều).

Updatable view: hạn chế (một bảng, không aggregate). `INSTEAD OF` trigger: [routines.md](routines.md).

**Ghi chú:** SQL Server không `CREATE MATERIALIZED VIEW`. PostgreSQL không indexed view kiểu SS (có `CREATE MATERIALIZED VIEW` + unique). Port báo cáo: chọn một mô hình, không mix tên.

---

## 9. SEQUENCE & replication (PG 19)

```sql
CREATE SEQUENCE order_no START WITH 1 INCREMENT BY 1 CACHE 50;

-- SQL Server
SELECT NEXT VALUE FOR dbo.order_no;
ALTER TABLE dbo.Orders ADD OrderNo bigint NOT NULL
    DEFAULT (NEXT VALUE FOR dbo.order_no);

-- PostgreSQL
SELECT nextval('order_no');
SELECT currval('order_no');          -- session đã nextval
SELECT setval('order_no', 1000, true);
```

`IDENTITY` = sequence ẩn — ưu tiên hơn `serial`. `CACHE` / `CYCLE` / `OWNED BY`. Rollback **không** trả số — lỗ là đúng.

SQL Server sequence không đi logical replication kiểu PG; AG/identity: mỗi replica không tự `IDENTITY` riêng trên cùng DB AG (một copy). Sharding: range sequence / `SEQUENCE` per node — thiết kế ứng dụng.

### 9.1 ALL SEQUENCES / REFRESH SEQUENCES

**PostgreSQL 19:** logical replication **đồng bộ sequence** (publisher → subscriber). Trước 19: sequence trên replica lệch — `setval` tay sau failover.

- `CREATE` / `ALTER PUBLICATION … ALL SEQUENCES` (kèm hoặc tách `ALL TABLES`).
- `CREATE SUBSCRIPTION` / `ALTER SUBSCRIPTION … REFRESH PUBLICATION` đồng bộ **tồn tại** object (tạo/xóa sequence theo pub).
- `ALTER SUBSCRIPTION … REFRESH SEQUENCES` — **chỉ giá trị** (`last_value` / LSN trang), **không** tạo/xóa sequence.
- `pg_get_sequence_data()` (+ LSN trang sequence).
- `sync_seq_error_count`; `sync_error_count` → `sync_table_error_count` (dashboard cũ vỡ).

```sql
-- Publisher 19
CREATE PUBLICATION pub_all
    FOR ALL TABLES
    ALL SEQUENCES;

-- Hoặc ALTER PUBLICATION pub_all ADD ALL SEQUENCES;  -- đối chiếu cú pháp docs 19

-- Subscriber: sau khi thêm sequence mới trên publisher
ALTER SUBSCRIPTION sub_all REFRESH PUBLICATION;
ALTER SUBSCRIPTION sub_all REFRESH SEQUENCES;   -- kéo giá trị
```

`REFRESH SEQUENCES` khi identity failover / sau `setval` trên primary. Physical standby **không** dùng sequence logical — dùng `WAIT FOR` LSN ([internal.md](internal.md) §15), không `ALL SEQUENCES`.

Thứ tự sau khi thêm `CREATE SEQUENCE` / bảng `IDENTITY` mới trên publisher:

1. DDL replicate hoặc `REFRESH PUBLICATION` — object xuất hiện subscriber.
2. `REFRESH SEQUENCES` — `last_value` khớp (tránh subscriber cấp trùng PK sau promote).
3. Theo dõi `sync_seq_error_count` (tách khỏi `sync_table_error_count`).

Chỉ bước 1: sequence tồn tại, **giá trị** có thể 1 trong khi primary đã 1e9. Promote sớm = duplicate key. Chỉ bước 2 khi sequence chưa có trên sub → lỗi (không tạo object).

Khác replication 19 (không lặp hết): `CREATE SUBSCRIPTION … SERVER` (tham số `postgres_fdw`); `wal_level = replica` có thể **bật logical không restart**; publication `EXCEPT` khi `ALL TABLES`; `retain_dead_tuples` + `max_retention_duration` (xmin!).

**Ghi chú:** `nextval` trong `SELECT` “cho vui” tốn số. `CACHE` lớn + failover: nhảy khoảng trống lớn. Slot + `retain_dead_tuples` = bloat — [concurrency.md](concurrency.md). `IDENTITY` ẩn cũng là sequence — pub `ALL SEQUENCES` cần cover nếu failover dựa nextval. Đối chiếu docs 19 trước GA (tên mệnh đề `ALL SEQUENCES`).

---

## 10. REPACK vs REBUILD

**Hình dung hai pha.** `VACUUM` thường = dọn rác *trong* file đang dùng (người vẫn đọc). `REPACK` / `VACUUM FULL` = **photo bản sạch** sang file mới rồi **đổi tên**. Không concurrent: cửa đóng suốt lúc chụp (`ACCESS EXCLUSIVE`). `CONCURRENTLY`: chụp trong lúc khách vẫn vào, ghi nhật ký thay đổi (logical decoding), rồi khóa cửa **chỉ lúc đổi tên**. Khóa ngắn, nhưng WAL/slot tăng lúc chụp.

Thống nhất ý `VACUUM FULL` (compact heap) + `CLUSTER` (sort theo index). Lệnh cũ **còn chạy**.

```sql
-- PostgreSQL 19
REPACK employees;
REPACK (CONCURRENTLY) employees USING INDEX employees_pkey;
REPACK (VERBOSE, ANALYZE) employees;
REPACK (CONCURRENTLY, ANALYZE) employees USING INDEX employees_pkey;

-- Cũ, vẫn chạy
VACUUM FULL employees;
CLUSTER employees USING employees_pkey;
```

`REPACK` copy bảng, sort theo index (nếu `USING INDEX`), swap file. Mặc định **`ACCESS EXCLUSIVE` suốt copy** — OLTP đứng. Không thay `TRUNCATE` (rỗng bảng ≠ compact). Không trong transaction block (mục 2).

```sql
-- SQL Server
ALTER INDEX ix_orders_customer ON dbo.Orders REBUILD
    WITH (ONLINE = ON);              -- Enterprise / Developer tương ứng

ALTER INDEX ALL ON dbo.Orders REBUILD;

ALTER TABLE dbo.Orders REBUILD;      -- heap / compression
```

`REORGANIZE` (SS) khác `REBUILD`: online hơn, không đổi compaction cùng mức. `FILLFACTOR` / `fillfactor` (PG) lúc tạo index. SS `ONLINE = ON` Standard: giới hạn historically — 2025 edition: kiểm Learn.

Bloat PG: dead tuple + `xmin` horizon — [concurrency.md](concurrency.md), [internal.md](internal.md) §11. Autovacuum 19 parallel index / scoring **không** thay `REPACK` khi bloat nặng.

So lệnh compact:

| Lệnh | Exclusive suốt copy? | Giữ thứ tự index sau insert? | Trong txn? |
|---|---|---|---|
| `VACUUM` (thường) | không | không (không sort) | không |
| `VACUUM FULL` | có | không bắt buộc sort theo index | không |
| `CLUSTER` | có | **một lần** | không |
| `REPACK` | có (mặc định) | nếu `USING INDEX` — một lần | không |
| `REPACK (CONCURRENTLY)` | chỉ lúc **swap** | nếu `USING INDEX` — một lần | không |
| SS `REBUILD ONLINE` | ngắn hơn offline | clustered **duy trì** | không như INSERT |

`USING INDEX` không biến heap PG thành clustered index SQL Server: insert sau **không** giữ thứ tự. [indexes.md](indexes.md).

### 10.1 REPACK CONCURRENTLY

`CONCURRENTLY`: copy dưới **`SHARE UPDATE EXCLUSIVE`** (cho DML) + **logical decoding** vào stash (slot nội bộ); **`ACCESS EXCLUSIVE` chỉ lúc swap**.

| Pha | Lock | Việc |
|---|---|---|
| Copy heap/index | `SHARE UPDATE EXCLUSIVE` | DML vẫn vào; decode thay đổi vào stash |
| Apply stash | Vẫn concurrent (chi tiết docs 19) | Bắt kịp DML trong lúc copy |
| Swap file | `ACCESS EXCLUSIVE` **ngắn** | Đổi relfilenode; deadlock upgrade có thể |

GUC `max_repack_replication_slots`. Slot + WAL lúc concurrent — disk `pg_wal` / slot giữ xmin. Một lúc một concurrent repack historically. Deadlock lock upgrade lúc swap — retry, `lock_timeout`.

Hạn chế (**beta**, đọc reference hiện tại):

- Partitioned / **unlogged** / một số catalog — có thể **cấm**.
- Không trong `BEGIN`.
- Không thay `VACUUM` thường / autovacuum.
- Logical decode đòi `wal_level` đủ (logical) — cluster `replica` 19 có thể bật logical không restart khi cần.

Job đêm: thử **bản sao** trước (thời gian, WAL, blocking swap). `VACUUM FULL` cũ vẫn được nếu chấp nhận exclusive suốt copy.

SQL Server gần: `ALTER INDEX … REBUILD WITH (ONLINE = ON)` / rebuild clustered — **không** logical decoding, version store / snapshot khác.

**Ghi chú:** `CLUSTER` job cũ không tự thành `REPACK (CONCURRENTLY)` đã đo. Fail giữa chừng: kiểm object/slot dở; đừng để slot orphan. `REPACK` rewrite = `ctid` đổi — [dml.md](dml.md) xóa theo `ctid` lô phải xong trước, không giữ `ctid` qua repack.

---

## 11. Property graph — đã rút khỏi PostgreSQL 19

SQL/PGQ, `CREATE PROPERTY GRAPH` và `GRAPH_TABLE` đã bị rút trong Beta 4; không còn là API PostgreSQL 19. Xem [thông báo Beta 4](https://www.postgresql.org/about/news/postgresql-19-beta-4-released-3386/). Mô hình hóa đỉnh/cạnh bằng bảng quan hệ, query đường đi cố định bằng JOIN và đường đi nhiều bước bằng [recursive CTE](cte-subqueries.md). SQL Server SQL Graph là hệ cú pháp riêng, không thể thay thế trực tiếp SQL/PGQ.

---

## 12. IF EXISTS / CASCADE

```sql
DROP TABLE IF EXISTS orders;
DROP TABLE orders CASCADE;           -- PostgreSQL: kéo view/FK/dependent
DROP TABLE dbo.Orders;               -- SQL Server: lỗi nếu FK; DROP con trước
```

```sql
-- SQL Server 2016+
DROP TABLE IF EXISTS dbo.Orders;
DROP PROCEDURE IF EXISTS dbo.GetOrders;
CREATE OR ALTER PROCEDURE dbo.GetOrders AS …;

-- PostgreSQL
DROP INDEX CONCURRENTLY IF EXISTS ix_orders_customer;
CREATE INDEX IF NOT EXISTS ix_orders_customer ON orders (customer_id);
CREATE OR REPLACE VIEW v_paid AS …;
```

SQL Server **không** `CREATE TABLE IF NOT EXISTS` (dùng `IF OBJECT_ID … IS NULL`). **Không** `DROP TABLE … CASCADE` kiểu PG (`DROP SCHEMA` SS không cascade như PG — drop object trước).

CASCADE PostgreSQL có thể xóa view, FK, sequence OWNED BY và materialized view phụ thuộc. Review dependency trước khi DROP. PG 19 Beta 4 không có property graph.

`DROP DATABASE` không chạy trong session đang dùng DB đó. `RESTRICT` (PG, mặc định nhiều lệnh) ngược `CASCADE`.

**Ghi chú:** `CREATE OR REPLACE VIEW` không đổi cột ra/vào tùy ý (PG: đổi list cột hạn chế). `CREATE OR REPLACE FUNCTION` đổi `OUT` = overload / drop. `IF EXISTS` che typo tên — log vẫn nên biết object có thật.

---

## 13. Worked examples

### 13.1 Đơn giản — bảng + identity trong txn (PG) vs batch (SS)

```sql
-- PostgreSQL: một txn, ROLLBACK được
BEGIN;
CREATE TABLE customers (
    id   int GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    name text NOT NULL
);
CREATE TABLE orders (
    id          int GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    customer_id int NOT NULL,
    total       numeric(12,2) NOT NULL
);
ALTER TABLE orders
    ADD CONSTRAINT orders_customer_fk
    FOREIGN KEY (customer_id) REFERENCES customers (id) NOT VALID;
COMMIT;
-- VALIDATE lúc thấp điểm (khóa nhẹ hơn CREATE INDEX)
ALTER TABLE orders VALIDATE CONSTRAINT orders_customer_fk;
```

SQL Server: tách `GO`; FK `WITH CHECK` lúc thấp điểm; **không** gói `CREATE DATABASE` cùng txn app. CREATE INDEX thường trong BEGIN TRAN rollback được; RESUMABLE là ngoại lệ.

### 13.2 Trung bình — VIRTUAL + extended stats + index online

```sql
-- PG 18+ cột; 19 stats
ALTER TABLE invoice
    ADD COLUMN total numeric GENERATED ALWAYS AS (qty * price) VIRTUAL;

CREATE INDEX CONCURRENTLY ix_invoice_expr
    ON invoice ((qty * price));          -- expression; ngoài txn

CREATE STATISTICS st_inv_cust_total (dependencies)
    ON customer_id, total FROM invoice;
ANALYZE invoice;

-- SQL Server
ALTER TABLE dbo.Invoice ADD Total AS (Qty * Price) PERSISTED;
CREATE INDEX ix_invoice_total ON dbo.Invoice (Total)
    WITH (ONLINE = ON);
```

`VIRTUAL` không lưu; seek theo `total` = expression index (PG) hoặc `PERSISTED` (SS). Stats 19 giúp CE, không seek.

### 13.3 Thêm partition, đồng bộ sequence và REPACK

```sql
-- PostgreSQL: partition mới, mốc UTC rõ ràng
CREATE TABLE events_2026_10 PARTITION OF events
    FOR VALUES FROM ('2026-10-01 00:00:00+00') TO ('2026-11-01 00:00:00+00');

-- PostgreSQL 19 Beta 4: subscription/publication đã cấu hình trước.
ALTER SUBSCRIPTION sub_all REFRESH PUBLICATION;
ALTER SUBSCRIPTION sub_all REFRESH SEQUENCES;

-- Bảo trì ngoài transaction block; bảng/index phải tồn tại.
REPACK (CONCURRENTLY, ANALYZE) orders USING INDEX orders_pkey;
```

Ba bước thuộc các tác vụ vận hành riêng; không gói tất cả vào một transaction. PostgreSQL 19 không có SPLIT/MERGE partition hoặc property graph. SQL Server dùng partition function/scheme và `ALTER INDEX ... REBUILD`.

---

### 13.4 Rollback ALTER TABLE trên cả hai engine

DDL thông thường có thể rollback. Tạo cột rồi dùng cột trong SQL Server nên tách batch để tránh lỗi bind tên cột trước khi DDL chạy:

```sql
-- SQL Server, cùng một connection trong SSMS/sqlcmd
BEGIN TRAN;
ALTER TABLE dbo.Orders ADD tmp int;
GO
UPDATE dbo.Orders SET tmp = 1;
ROLLBACK TRAN; -- cột tmp và UPDATE đều được hoàn nguyên
```

```sql
-- PostgreSQL
BEGIN;
ALTER TABLE orders ADD COLUMN tmp integer;
UPDATE orders SET tmp = 1;
ROLLBACK; -- cột tmp và UPDATE đều được hoàn nguyên
```

Bảng Orders phải tồn tại và chưa có cột tmp. Không nhầm `GO` với `COMMIT`; chương trình dùng driver cần gửi hai batch qua cùng connection.

---

### 13.5 VALIDATE vs NOCHECK

```sql
-- PG: hàng mới đã kiểm từ ADD NOT VALID; VALIDATE quét cũ
ALTER TABLE orders VALIDATE CONSTRAINT orders_customer_fk;

-- SS: sau ETL, phải WITH CHECK để trusted + join elimination
ALTER TABLE dbo.Orders WITH CHECK CHECK CONSTRAINT FK_Orders_Customer;
```

`NOCHECK` rồi quên `WITH CHECK` = FK untrusted — [joins.md](joins.md) §3.

---

## 14. Best practices & checklist

- PG: DDL trong txn trừ `CONCURRENTLY`/`REPACK`/`VACUUM`/`REFRESH CONCURRENTLY`.
- Cả hai: phân biệt DDL rollback được và lệnh cấm transaction; giữ batch/transaction vừa đủ để kiểm soát khóa.
- Add FK/CHECK: `NOT VALID` + `VALIDATE` (PG); không `NOCHECK` lâu (SS).
- Generated: `VIRTUAL` khi chỉ đọc; `STORED`/`PERSISTED` khi index/filter nặng; stats 19 trên VIRTUAL.
- Partition: PK gồm khóa; `SPLIT`/`MERGE` trên bản sao trước; SS `NEXT USED`.
- View: liệt kê cột; indexed view / matview chọn đúng mô hình.
- Sequence: chấp nhận lỗ; PG 19 `ALL SEQUENCES` + `REFRESH SEQUENCES` sau failover/object mới.
- Bloat: autovacuum trước; `REPACK (CONCURRENTLY)` có chủ đích (slot/WAL/swap).
- Graph: metadata + index FK; beta; không variable-length.
- `DROP CASCADE` review phụ thuộc.
- `PREVIEW_FEATURES` / PG 19 beta không lặng lẽ lên prod.

```text
□ Lock_timeout khi ALTER production
□ PG CONCURRENTLY/REPACK và SS RESUMABLE ngoài txn; ONLINE thường có thể trong txn
□ Không rewrite kiểu cột lớn giờ cao điểm
□ VALIDATE CONSTRAINT sau NOT VALID
□ SPLIT có filegroup / partition đích; cửa sổ khóa
□ REFRESH PUBLICATION rồi REFRESH SEQUENCES
□ REPACK CONCURRENTLY đo WAL + swap
□ PREVIEW_FEATURES / PG 19 beta không lặng lẽ lên prod
```

---

## 15. Bẫy khi review

- SQL Server DDL trong transaction dài giữ schema lock và log đến COMMIT/ROLLBACK.
- PG `CREATE INDEX CONCURRENTLY` / `REPACK` / `REFRESH CONCURRENTLY` *trong* `BEGIN`.
- `ALTER COLUMN TYPE` trên TEXT lớn không ước lượng rewrite.
- `ADD COLUMN … DEFAULT now()` tưởng metadata-only.
- FK `NOCHECK` (SS) tưởng như `NOT VALID`.
- Indexed view thiếu `COUNT_BIG` / `SCHEMABINDING`.
- `REFRESH MATERIALIZED VIEW` (không concurrent) giờ cao điểm.
- `SELECT *` view, rồi `ALTER TABLE ADD` tin API tự có cột.
- `NATURAL`/tên cột generated đổi silently.
- `DROP TABLE CASCADE` nuốt view / graph phụ thuộc.
- `REPACK` trên unlogged/partitioned không đọc hạn chế.
- `VACUUM FULL` thay `REPACK (CONCURRENTLY)` trên OLTP chưa đo exclusive.
- `CLUSTER` cron = `REPACK CONCURRENTLY` chưa test slot.
- Sequence replica pre-19 / quên `REFRESH SEQUENCES` (chỉ giá trị) vs `REFRESH PUBLICATION` (object).
- Dùng CREATE PROPERTY GRAPH đã bị rút khỏi PG 19 Beta 4.
- Port `IDENTITY` sang `serial` rồi `TRUNCATE` không `RESTART IDENTITY`.
- SQL Server SPLIT RANGE thiếu NEXT USED; PG SPLIT PARTITION đã bị rút khỏi 19.
- Extended stats trên VIRTUAL rồi tin seek không cần expression index.
- `PREVIEW` vector index trong script DDL bắt buộc.

---

## 16. Version gates

| Mục | SQL Server | PostgreSQL |
|---|---|---|
| DDL transactional | DDL thường dùng có; ngoại lệ mục 2 | hầu hết; ngoại lệ mục 2 |
| `CREATE INDEX ONLINE` | edition / phiên bản | `CONCURRENTLY` (ngoài txn) |
| Default constant không rewrite | có (bản gần) | **11+** |
| Generated `VIRTUAL` | computed non-persisted | **18+** `VIRTUAL` |
| Generated `PERSISTED`/`STORED` | lâu | `STORED` lâu |
| Extended stats trên VIRTUAL | stats computed (khác API) | **19** |
| `pg_clear_extended_stats` | — | **19** |
| `NOT VALID` FK/CHECK | `NOCHECK` khác ngữ nghĩa | lâu |
| CHECK `[NOT] ENFORCED` | — | **19** |
| Declarative `PARTITION BY` | function/scheme | lâu |
| `SPLIT`/`MERGE` partition tại chỗ | `ALTER PARTITION FUNCTION` | **19 beta** (`ALTER TABLE`) |
| `DETACH CONCURRENTLY` | `SWITCH` | **14+** |
| `CREATE MATERIALIZED VIEW` | indexed view | lâu |
| Sequence logical replication | — | **19** `ALL SEQUENCES` / `REFRESH SEQUENCES` |
| `REPACK` / `REPACK (CONCURRENTLY)` | `ALTER INDEX REBUILD` | **19 beta** |
| CREATE PROPERTY GRAPH | NODE/EDGE thuộc SQL Graph riêng | Đã rút khỏi 19 Beta 4 |
| `CREATE OR ALTER` | proc/view một số object | `CREATE OR REPLACE` |
| `DROP IF EXISTS` | **2016+** | lâu |
| Compat 170 / `PREVIEW_FEATURES` | **2025** | — |
| JIT default off | — | **19** |

DML sau đổi schema (`OVERRIDING`, `TRUNCATE`, bulk và chia khoảng application-time): [dml.md](dml.md). Join PK/FK mới: [joins.md](joins.md). Trạng thái SQL/PGQ: [select.md](select.md) §11. Vacuum/WAL: [internal.md](internal.md).

---

## Nguồn chính thức

Đối chiếu ngày **03/10/2026**; PostgreSQL **19 Beta 4**. Trạng thái beta và build/CU có thể thay đổi; xem [baseline và quy ước ví dụ](README.md#trạng-thái-phiên-bản-và-cách-kiểm-chứng).

- [T-SQL CREATE INDEX](https://learn.microsoft.com/en-us/sql/t-sql/statements/create-index-transact-sql?view=sql-server-ver17)
- [PostgreSQL CREATE TABLE](https://www.postgresql.org/docs/19/sql-createtable.html)
- [PostgreSQL REPACK](https://www.postgresql.org/docs/19/sql-repack.html)
