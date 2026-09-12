# Dialect, identifier & quy ước

> **Baseline:** SQL Server **2025** (T-SQL) · PostgreSQL **19**.  
> SQL chuẩn: ISO/IEC 9075 (SQL:2023 + SQL/PGQ). Engine **không** implement đủ chuẩn; luôn kiểm tra dialect.

SQL không phải một ngôn ngữ. ANSI/ISO định nghĩa lõi (`SELECT`, `JOIN`, `NULL`), mỗi engine thêm dialect, identifier, batch, collation và session option riêng. Port script giữa SQL Server và PostgreSQL thất bại trước hết ở *quy ước* — folding tên, `search_path` / default schema, `GO` vs `;`, three-valued logic — chứ không phải ở `SELECT`. File này là lớp nền: [typesystem.md](typesystem.md), [literals.md](literals.md), [keywords.md](keywords.md) giả định bạn đã hiểu các luật dưới đây.

Kiến trúc (process, TDS vs libpq, catalog, WAL): [internal.md](internal.md). Isolation: [transactions.md](transactions.md). File này chỉ *parser / session / identifier*.

---

## Mục lục

- [1. Tổng quan \& triết lý](#1-tổng-quan--triết-lý)
- [2. Ba lớp SQL](#2-ba-lớp-sql)
- [3. Identifier](#3-identifier)
  - [3.1 Unquoted vs quoted](#31-unquoted-vs-quoted)
  - [3.2 Folding \& độ dài](#32-folding--độ-dài)
  - [3.3 Prefix đặc biệt (SQL Server)](#33-prefix-đặc-biệt-sql-server)
  - [3.4 Phân giải tên object](#34-phân-giải-tên-object)
  - [3.5 CR/LF, encoding tên, `MULE_INTERNAL`](#35-crlf-encoding-tên-mule_internal)
- [4. Comment, batch, terminator](#4-comment-batch-terminator)
  - [4.1 Comment](#41-comment)
  - [4.2 `GO` vs `;`](#42-go-vs-)
  - [4.3 Phạm vi biến qua batch](#43-phạm-vi-biến-qua-batch)
- [5. Schema, catalog, search path](#5-schema-catalog-search-path)
  - [5.1 SQL Server: default schema \& 3-part](#51-sql-server-default-schema--3-part)
  - [5.2 PostgreSQL: `search_path`](#52-postgresql-search_path)
  - [5.3 Cross-database \& FDW](#53-cross-database--fdw)
- [6. NULL — ba giá trị logic](#6-null--ba-giá-trị-logic)
  - [6.1 `WHERE` vs `CHECK`](#61-where-vs-check)
  - [6.2 `UNIQUE` + NULL](#62-unique--null)
- [7. Case, collation, encoding](#7-case-collation-encoding)
- [8. Parameter \& quoting](#8-parameter--quoting)
  - [8.1 Parameter](#81-parameter)
  - [8.2 Dynamic SQL](#82-dynamic-sql)
- [9. Session SET](#9-session-set)
- [10. Compatibility, PREVIEW, protocol](#10-compatibility-preview-protocol)
  - [10.1 Compat 170 vs PostgreSQL không compat](#101-compat-170-vs-postgresql-không-compat)
  - [10.2 `PREVIEW_FEATURES`](#102-preview_features)
  - [10.3 `standard_conforming_strings` \& `escape_string_warning`](#103-standard_conforming_strings--escape_string_warning)
  - [10.4 TDS 8 / TLS 1.3 — client breaking](#104-tds-8--tls-13--client-breaking)
  - [10.5 Edition / SKU chỉ khi đụng SET / identifier](#105-edition--sku-chỉ-khi-đụng-set--identifier)
- [11. Hai session — ví dụ làm việc](#11-hai-session--ví-dụ-làm-việc)
- [12. Checklist nâng cấp (dialect / session)](#12-checklist-nâng-cấp-dialect--session)
- [13. Best practices \& checklist](#13-best-practices--checklist)
- [14. Bẫy khi review](#14-bẫy-khi-review)
- [15. Version gates](#15-version-gates)
- [Phụ lục A. `@@OPTIONS` / GUC](#phụ-lục-a-options--guc--soi-session-khi-chạy-được-trên-máy-tôi)
- [Phụ lục B. Identifier CR/LF](#phụ-lục-b-identifier-crlf--query-catalog-trước-pg_upgrade)

---

## 1. Tổng quan & triết lý

Hai engine cùng “SQL” nhưng khác nhau ở bốn chỗ hay gây bug khi port:

| Trục | SQL Server | PostgreSQL |
|---|---|---|
| Tên unquoted | Không phân biệt hoa/thường (collation); lưu theo cách viết | **Fold về chữ thường** |
| Kết thúc lệnh | `;` khuyến nghị; `GO` là lệnh *client* | `;` bắt buộc giữa statement |
| Catalog | 4-part: server.database.schema.object | Một statement = một database; cross-DB qua FDW |
| Session | Hàng chục `SET ANSI_*` ảnh hưởng parser/index | `search_path`, `TimeZone`, timeout |

Viết portable khi cú pháp ANSI đủ; khi cần hiệu năng / tính năng mới — dùng dialect tường minh, ghi chú engine, đừng giả định “chuẩn sẽ cứu”. Từ khóa lệch: [keywords.md](keywords.md). Isolation lệch: [transactions.md](transactions.md).

**Ghi chú:** “Cùng chạy trên SSMS và `psql`” không chứng minh cùng ngữ nghĩa. SSMS split `GO`, set `QUOTED_IDENTIFIER`, language `us_english`. `psql` tôn trọng `standard_conforming_strings`, không có `GO`, `search_path` mặc định `"$user", public`. Hai session khác client = hai parser path.

---

## 2. Ba lớp SQL

| Lớp | Vai trò | SQL Server | PostgreSQL |
|---|---|---|---|
| **ANSI/ISO** | Cú pháp chung | Hỗ trợ phần lớn, lệch T-SQL | Gần chuẩn hơn, thêm extension |
| **Dialect** | Ngôn ngữ riêng | T-SQL (`TOP`, `OUTPUT`, `GO`, `WAITFOR`) | `LIMIT`, `RETURNING`, `LATERAL`, PL/pgSQL |
| **Extension / engine** | Ngoài SQL | CLR, In-Memory, Vector, Fabric, CES | Extension (`pgvector`, `pg_plan_advice`, PostGIS) |

```sql
-- Cùng ý: lấy 10 hàng — ba cách, không thay thế mù
-- SQL Server
SELECT TOP (10) Id FROM dbo.Orders ORDER BY Id;

-- PostgreSQL
SELECT id FROM orders ORDER BY id LIMIT 10;

-- ANSI (cả hai)
SELECT id FROM orders ORDER BY id
OFFSET 0 ROWS FETCH NEXT 10 ROWS ONLY;
```

**Ghi chú:**

- `FETCH` portable; `TOP` / `LIMIT` đọc nhanh hơn với người quen dialect — chọn một convention trong repo.
- Lớp extension **không** có trên engine kia: `VECTOR_SEARCH` (SQL Server, **PREVIEW**) ≠ `pgvector` operator `<=>`.
- SQL/PGQ (`GRAPH_TABLE`) là PostgreSQL **19** (**beta** đến GA ~10/2026) — [select.md](select.md), [ddl.md](ddl.md), [keywords.md](keywords.md). SQL Server Graph cũ (`NODE`/`EDGE`) **không** phải SQL/PGQ.

Hai session — cùng “10 hàng mới nhất”, khác guarantee nếu thiếu `ORDER BY`:

```text
T1 (SQL Server): SELECT TOP (10) * FROM dbo.Orders;     -- 10 hàng tùy plan
T2 (PostgreSQL): SELECT * FROM orders LIMIT 10;         -- 10 hàng tùy plan
-- Thêm ORDER BY mới so được. Không ORDER BY = không portable.
```

---

## 3. Identifier

### 3.1 Unquoted vs quoted

Unquoted phải là identifier hợp lệ và **không** trùng reserved word. Quoted giữ nguyên ký tự, cho phép khoảng trắng, từ khóa, hoa/thường khác nhau.

```sql
-- Unquoted: luật phụ thuộc engine
CREATE TABLE orders (order_id int);

-- SQL Server: ngoặc vuông luôn; dấu " khi QUOTED_IDENTIFIER ON (mặc định hiện đại)
CREATE TABLE [Order] ([Id] int NOT NULL);
CREATE TABLE "Order" ("Id" int NOT NULL);

-- PostgreSQL: chỉ dấu "
CREATE TABLE "Order" ("Id" int NOT NULL);
```

| | SQL Server | PostgreSQL |
|---|---|---|
| Unquoted | Case-insensitive theo collation DB; lưu *như đã viết* | **Fold về chữ thường** |
| Quoted | `[name]` hoặc `"name"` | chỉ `"name"` |
| Ký tự hợp lệ (unquoted) | chữ, `_`, `@`, `#`, `$`; bắt đầu bằng chữ / `_` / `@` / `#` | chữ, `_`, số, `$`; **không** bắt đầu bằng số |
| Max length | 128 (`sysname`) | 63 byte mặc định (`NAMEDATALEN − 1`) |

```sql
-- PostgreSQL: hai object khác nhau
CREATE TABLE Orders (id int);     -- bảng "orders"
CREATE TABLE "Orders" (id int);   -- bảng "Orders"
-- SELECT * FROM Orders;          -- đọc "orders"
-- SELECT * FROM "Orders";        -- đọc "Orders"
```

**Ghi chú:**

- Copy `Orders` từ SSMS sang `psql` mà không quote → thành `orders`. Nếu dump PG đã có `"Orders"` và `orders`, bạn có hai bảng.
- `[Order]` trên SQL Server **không** tự thành `"Order"` trên PostgreSQL — tool port phải quote có chủ đích.
- Tránh tên cần quote (`user`, `order`, `group`) — [keywords.md § hay đụng](keywords.md#21-hay-đụng-identifier).
- `QUOTED_IDENTIFIER OFF`: `"Orders"` là *chuỗi* T-SQL, không phải identifier. Proc có indexed view / computed persisted / XML index **đòi** `ON` — §9.

### 3.2 Folding & độ dài

PostgreSQL folding là **lowercase Unicode**, không phải case-fold locale. `"İ"` (I chấm Turkish) quoted khác `İ` unquoted.

SQL Server so sánh identifier unquoted theo collation database (thường CI). `CREATE TABLE Foo` rồi `FROM FOO` thành công; catalog `sys.tables.name` vẫn là `Foo` nếu bạn viết vậy.

Cắt tên im lặng: PostgreSQL identifier dài hơn 63 byte bị **cắt** (có warning). Hai tên khác nhau ở ký tự thứ 64 có thể đụng nhau.

```sql
-- PostgreSQL: kiểm tra
SELECT length('a_very_long_name_that_exceeds_the_typical_limit_of_sixty_three_x');
-- Đừng dựa vào khác biệt sau byte 63.

-- UTF-8: một chữ 'ệ' = nhiều byte → giới hạn 63 byte, không 63 ký tự
```

Hai session — ORM vs DBA:

```text
T1 (SSMS): CREATE TABLE dbo.CustomerOrderHistoryDetailLine;
           -- 128 ký tự sysname: OK nếu ≤ 128
T2 (psql): CREATE TABLE customerorderhistorydetailline_extra_suffix_here;
           -- cắt / đụng tên khác đã có cùng 63 byte đầu
```

**Ghi chú:** Đổi `NAMEDATALEN` = rebuild PostgreSQL từ source, không phải GUC session. SQL Server `sysname` = `nvarchar(128)` — không phụ thuộc Standard vs Enterprise.

### 3.3 Prefix đặc biệt (SQL Server)

| Prefix | Ý nghĩa |
|---|---|
| `@var` | Biến / tham số T-SQL |
| `@@TRANCOUNT` | Hàm hệ thống kiểu “global variable” — quy ước `@@`, không phải scope thật |
| `#temp` | Bảng tạm local (session, `tempdb`) |
| `##glob` | Bảng tạm global (mọi session thấy, sống đến khi session cuối nhả) |

```sql
-- SQL Server
CREATE TABLE #Work (Id int NOT NULL);
CREATE TABLE ##Shared (Id int NOT NULL);

-- PostgreSQL: không có prefix # — dùng TEMP
CREATE TEMP TABLE work (id int NOT NULL);
-- Tồn tại đến hết session (ON COMMIT PRESERVE ROWS mặc định) hoặc ON COMMIT DROP
```

**Ghi chú:** `#temp` không nhìn thấy từ session khác; stored proc tạo `#t` mỗi lần gọi là bảng khác. PostgreSQL `TEMP` cũng per-session, schema `pg_temp_nnn`. Đừng giả định temp table sống qua connection pool *reuse* nếu session reset không drop — pool tốt thì `DISCARD ALL` / `sp_reset_connection`. Kiến trúc `tempdb` vs `pgsql_tmp`: [internal.md](internal.md).

Hai session — `#temp` vs `##temp`:

```text
T1: CREATE TABLE #T (Id int); INSERT #T VALUES (1);
T2: SELECT * FROM #T;              -- lỗi: không thấy bảng T1
T1: CREATE TABLE ##G (Id int); INSERT ##G VALUES (1);
T2: SELECT * FROM ##G;             -- thấy, đến khi T1 (và session khác) nhả
```

### 3.4 Phân giải tên object

```
SQL Server : [server].[database].[schema].[object]
PostgreSQL : database là connection; trong statement: [schema.]object
```

```sql
-- SQL Server: 1 / 2 / 3 / 4 phần
SELECT * FROM Orders;                 -- schema mặc định của user + dbo fallback
SELECT * FROM dbo.Orders;
SELECT * FROM Sales.dbo.Orders;
SELECT * FROM [linked].[Sales].dbo.Orders;

-- PostgreSQL
SELECT * FROM orders;                 -- search_path
SELECT * FROM app.orders;             -- tường minh — khuyến nghị trong app
-- SELECT * FROM otherdb.app.orders;  -- không hợp lệ; dùng postgres_fdw / dblink
```

**Ghi chú:** 4-part name SQL Server đi qua linked server — isolation, collate conflict, collocation optimizer khác hẳn local. PostgreSQL `postgres_fdw` (**19**: txn `READ ONLY` / `DEFERRABLE` được đẩy sang remote; **không ghi** remote từ txn read-only). Synonym SQL Server (tên giả) dễ làm plan cache / ownership chaining khó đọc; PG không có synonym, dùng view hoặc `search_path`. Protocol linked server 2025: TDS 8 / TLS 1.3 — §10.4.

### 3.5 CR/LF, encoding tên, `MULE_INTERNAL`

PostgreSQL **19** chặn một số tên / encoding lúc `pg_upgrade` — đây là luật *identifier / cluster*, không phải optimizer.

| Thay đổi 19 | Hệ quả | WHY |
|---|---|---|
| CR/LF **cấm** trong tên database / role / tablespace | `pg_upgrade` từ chối | An ninh (tên chứa newline) |
| Encoding `MULE_INTERNAL` **gỡ** | Dump/restore encoding đó không còn | Hiếm, phức tạp; đổi encoding **trước** upgrade |
| Identifier vẫn 63 byte | Không đổi | Cắt im lặng như trước |

```sql
-- Đừng. Kể cả quoted, newline trong tên DB/role/tablespace là target chặn 19.
-- CREATE DATABASE "app
-- prod";                         -- CR/LF trong tên: upgrade 19 từ chối
```

SQL Server: tên object không chứa một số ký tự điều khiển theo identifier rules; không có `MULE_INTERNAL`. Collation / UTF-8 trên `varchar` là chuyện kiểu — [typesystem.md](typesystem.md) — không phải encoding cluster kiểu PG.

**Ghi chú:** Checklist nâng cấp dialect: soi `pg_database.datname`, `pg_roles.rolname`, `pg_tablespace.spcname` có byte `0x0A`/`0x0D` **trước** `pg_upgrade`. Đổi encoding `MULE_INTERNAL` trên lab, không đêm cutover. Dump phải client **19+** vì `standard_conforming_strings` — §10.3.

---

## 4. Comment, batch, terminator

### 4.1 Comment

```sql
-- comment một dòng (cả hai)
/* comment
   nhiều dòng */

SELECT 1; -- trailing
```

Lồng `/* */`: SQL Server **không** lồng; `/* outer /* inner */ vẫn đóng sớm`. PostgreSQL **lồng** được.

`--` chạy đến hết dòng. Chuỗi chứa `--` trong literal không phải comment.

```sql
SELECT 'http://example.com';   -- URL an toàn: nằm trong literal
-- SELECT http://x;            -- phần sau -- bị nuốt nếu không quote
```

Hai session — comment lồng khi generate SQL:

```text
T1 (SS):  /* meta /* generated */ still-code-here */ SELECT 1;
          -- parser đóng ở inner */; still-code-here là token
T2 (PG):  /* meta /* generated */ still-code-here */ SELECT 1;
          -- lồng: cả khối là comment; SELECT 1 chạy
```

### 4.2 `GO` vs `;`

`GO` **không** phải T-SQL. sqlcmd / SSMS / ADS cắt script thành batch, gửi từng batch tới engine. `psql`, Npgsql, JDBC **không** hiểu `GO`.

```sql
-- SQL Server (SSMS)
CREATE PROC dbo.P AS
BEGIN
    SELECT 1;
END
GO                                  -- bắt buộc: CREATE PROC là statement đầu batch

-- PostgreSQL: không có GO; ; kết thúc statement. psql meta-command bắt đầu bằng \
CREATE FUNCTION p() RETURNS int
LANGUAGE sql AS $$ SELECT 1; $$;
```

T-SQL cho phép bỏ `;` ở nhiều chỗ (không khuyến nghị). PostgreSQL **bắt buộc** `;` giữa các statement. SQL Server 2025 vẫn parse script cũ thiếu `;`, trừ CTE / `THROW` / `WITH` đứng sau lệnh khác — luôn viết `;` tường minh.

```sql
-- SQL Server: WITH ngay sau lệnh khác cần ; trước
SELECT 1
WITH cte AS (SELECT 1 AS x)         -- lỗi parse: WITH bị nuốt vào SELECT trước
SELECT * FROM cte;

SELECT 1;
WITH cte AS (SELECT 1 AS x)
SELECT * FROM cte;                  -- đúng
```

`sqlcmd -v` biến `$(name)` cũng là *client*. Đưa file đó vào Dapper nguyên văn → `$(name)` thành identifier.

### 4.3 Phạm vi biến qua batch

```sql
-- SQL Server: biến không sống qua GO
DECLARE @id int = 1;
GO
SELECT @id;                         -- lỗi: Must declare the scalar variable "@id"
```

**Trước:** một script “chạy được” trong SSMS vì cả file là nhiều batch. **Sau:** cùng file chạy bằng driver (một connection, không split `GO`) → `GO` thành identifier / syntax error.

PostgreSQL `DO $$ … $$;` là một statement; biến PL/pgSQL không thoát khỏi block. Session variable: `SET app.tenant = 'acme'` (custom GUC) sống theo session.

Hai session — pool reuse:

```text
T1: SET app.tenant = 'acme';  SET search_path TO acme, public;
    -- trả connection về pool, không DISCARD ALL
T2 (cùng connection): SELECT current_setting('app.tenant');  -- vẫn 'acme'
    SELECT * FROM orders;    -- vẫn schema acme nếu path chưa reset
```

SQL Server tương đương: `#temp` / `CONTEXT_INFO` / `SESSION_CONTEXT` / `SET` options sống theo session cho đến `sp_reset_connection` (pool ADO.NET thường gọi). Đừng giả định “request HTTP mới = session sạch” nếu pool tắt reset.

---

## 5. Schema, catalog, search path

### 5.1 SQL Server: default schema & 3-part

User có default schema (thường `dbo`). Unqualified name: default schema trước, rồi `dbo` (tùy ngữ cảnh).

```sql
-- SQL Server
SELECT SCHEMA_NAME();                 -- schema hiện tại
SELECT DB_NAME();                     -- database hiện tại
SELECT ORIGINAL_DB_NAME();            -- lúc connect
USE Sales;
ALTER USER [app] WITH DEFAULT_SCHEMA = app;
```

`USE` đổi database trong session — không có tương đương trong một script PostgreSQL (đổi connection / `\c`). Kiến trúc instance ⊃ database: [internal.md](internal.md).

**Ghi chú:** `USE` trong proc chạy trên connection app = đổi DB cho request sau nếu pool không reset. Production: 3-part `Sales.dbo.Orders` hoặc connection string đúng catalog, không `USE` giữa request.

### 5.2 PostgreSQL: `search_path`

Mặc định thường `"$user", public`. Object unquoted = **schema đầu tiên** trên path có tên đó.

```sql
-- PostgreSQL
SHOW search_path;
SET search_path TO app, public;
SELECT current_schemas(true);         -- gồm implicit pg_catalog, pg_temp

CREATE TABLE app.t (id int);
CREATE TABLE public.t (id int);
SET search_path TO app, public;
SELECT * FROM t;                      -- app.t
SET search_path TO public, app;
SELECT * FROM t;                      -- public.t
```

**Ghi chú:**

- `pg_catalog` luôn được tìm (trước hoặc ngầm). Đặt `search_path` độc hại + `SECURITY DEFINER` = classic privilege escalation — [routines.md](routines.md).
- App production: `SET search_path TO app, public` lúc connect **hoặc** luôn schema-qualify (`app.orders`).
- Đừng tạo schema `dbo` “cho giống SQL Server” trừ khi port có chủ đích.
- `SET LOCAL search_path` chỉ trong transaction hiện tại; `SET` session sống đến hết connection.

### 5.3 Cross-database & FDW

```sql
-- SQL Server
SELECT o.Id
FROM Sales.dbo.Orders AS o
JOIN Inventory.dbo.Stock AS s ON s.Sku = o.Sku;

-- PostgreSQL: foreign table
CREATE EXTENSION postgres_fdw;
CREATE SERVER inv FOREIGN DATA WRAPPER postgres_fdw
    OPTIONS (dbname 'inventory');
-- IMPORT FOREIGN SCHEMA / CREATE FOREIGN TABLE …
```

PG **19**: txn `READ ONLY` / `DEFERRABLE` được đẩy sang remote; **không ghi** qua FDW từ txn read-only.

Hai session — job “read-only nhưng upsert FDW”:

```text
T1: BEGIN TRANSACTION READ ONLY;
    INSERT INTO inv_stock (sku, qty) VALUES ('A', 1);
    -- PG 19: lỗi — không ghi remote từ txn read-only
    COMMIT;

T2: BEGIN;                          -- read-write
    INSERT INTO inv_stock (sku, qty) VALUES ('A', 1);
    COMMIT;                         -- OK nếu quyền FDW đủ
```

SQL Server 3-part không có “READ ONLY txn chặn ghi DB kia” cùng cơ chế; quyền + linked server option quyết định. Đừng port isolation `READ ONLY` PG như thể T-SQL `SET TRANSACTION ISOLATION LEVEL`.

---

## 6. NULL — ba giá trị logic

SQL dùng **three-valued logic**: `TRUE` / `FALSE` / `UNKNOWN`. `NULL` không phải “giá trị đặc biệt của mọi kiểu” theo nghĩa sentinel — nó là *thiếu*. So sánh với `NULL` bằng `=` cho `UNKNOWN`, không phải `TRUE`.

```sql
WHERE x = NULL;          -- luôn UNKNOWN → hàng bị loại khỏi WHERE
WHERE x IS NULL;         -- đúng
WHERE NOT (x = y);       -- loại hàng khi x hoặc y NULL (UNKNOWN)
WHERE x <> y;            -- tương tự: NULL không “khác”
```

Kiểu & literal NULL: [typesystem.md](typesystem.md), [literals.md](literals.md). So sánh NULL-safe: `IS [NOT] DISTINCT FROM` — [operators.md](operators.md). PG **19** fold `IS [NOT] DISTINCT FROM NULL` → `IS [NOT] NULL` (cùng nghĩa, plan gọn) — đó là optimizer, không đổi ngữ nghĩa.

### 6.1 `WHERE` vs `CHECK`

| Ngữ cảnh | `UNKNOWN` nghĩa là |
|---|---|
| `WHERE` / `HAVING` / `WHEN` / `JOIN ON` | Hàng / nhánh **loại** |
| `CHECK` constraint | **Chấp nhận** (không reject) |
| `IF` T-SQL / `IF` PL/pgSQL | Đi nhánh false (không vào `THEN`) |

```sql
-- CHECK (qty > 0): INSERT qty = NULL → thành công cả hai engine
-- WHERE qty > 0: hàng qty NULL biến mất

CREATE TABLE t (
    qty int CHECK (qty > 0)          -- NULL vẫn insert được
);
INSERT INTO t VALUES (NULL);         -- OK
SELECT * FROM t WHERE qty > 0;       -- không ra hàng NULL
```

Muốn cấm NULL: `NOT NULL` tường minh, không dựa vào `CHECK (qty > 0)`. Chi tiết: [constraints.md](constraints.md).

### 6.2 `UNIQUE` + NULL

`NULL ≠ NULL` nên hai hàng `(NULL)` không “trùng” theo mặc định.

| Engine | Nhiều NULL trong UNIQUE |
|---|---|
| SQL Server | Cho phép nhiều NULL |
| PostgreSQL | Cho phép nhiều NULL; `UNIQUE NULLS NOT DISTINCT` (PG 15+) cấm |
| SQL Server “cấm nhiều NULL” | Filtered unique index `WHERE col IS NOT NULL` **không** cấm nhiều NULL — NULL vốn không vào index đó. Muốn tối đa một NULL: filtered `WHERE col IS NULL` kiểu trick hoặc computed column |

Hai session — unique nullable:

```text
T1: INSERT INTO t (email) VALUES (NULL); COMMIT;
T2: INSERT INTO t (email) VALUES (NULL); COMMIT;
-- Mặc định cả hai: OK (hai NULL)
-- PG UNIQUE NULLS NOT DISTINCT: T2 lỗi unique
```

---

## 7. Case, collation, encoding

So sánh chuỗi **không portable**: `'A' = 'a'` đúng trên SQL Server CI, sai trên PostgreSQL mặc định (libc `C` / `en_US.utf8` thường case-sensitive).

```sql
-- SQL Server: collation theo instance / database / cột
SELECT name, collation_name FROM sys.databases;
-- CI = case-insensitive, CS = case-sensitive
-- AI/AS = accent; UTF8 / SC (supplementary) trên collation hiện đại
-- Ví dụ: Latin1_General_100_CI_AI_SC_UTF8

SELECT CASE WHEN N'A' = N'a' THEN 1 ELSE 0 END;   -- 1 nếu CI

-- PostgreSQL: encoding cluster (thường UTF8); collation ICU / libc
SHOW server_encoding;
SHOW lc_collate;
-- PG 15+: ICU collation DETERMINISTIC = false → so khớp nondeterministic (case-insensitive)
CREATE COLLATION ci (provider = icu, locale = 'und-u-ks-level2', deterministic = false);
```

**Ghi chú:**

- Index btree phụ thuộc collation. Đổi collation cột = rebuild index.
- Nondeterministic collation (PG ICU / một số SQL Server) **cấm** trên unique/PK hoặc hạn chế — đọc docs trước khi dùng làm PK chuỗi.
- SQL Server `LIKE` + CI: `'a' LIKE '[A-Z]'` có thể true. PostgreSQL `LIKE` không có character class — [operators.md](operators.md).
- Encoding SQL Server: `varchar` theo code page collation; `nvarchar` UTF-16. PostgreSQL: mọi text theo encoding DB (UTF8). Đừng map `varchar` SQL Server → `varchar` PG rồi giả định byte length giống nhau.
- SQL Server 2025: Chinese collation GB18030-2022 (compat **160+**) — chỉ khi locale cần. PG 19: Unicode 17.0.0; GB18030 encoding 2022. Không đổi identifier folding.

Hai session — unique `'A'` / `'a'`:

```text
T1 (SS, CI): INSERT dbo.T (Code) VALUES (N'A');
T2 (SS, CI): INSERT dbo.T (Code) VALUES (N'a');  -- unique fail
T1 (PG, C):  INSERT INTO t (code) VALUES ('A');
T2 (PG, C):  INSERT INTO t (code) VALUES ('a');  -- OK, hai hàng
```

---

## 8. Parameter & quoting

### 8.1 Parameter

Nối chuỗi SQL = injection. Dùng parameter cho *giá trị*; quote identifier bằng API engine cho *tên object* động.

```sql
-- SQL Server
SELECT * FROM dbo.Orders WHERE Id = @id;
EXEC dbo.GetOrder @id = 1;
EXEC sys.sp_executesql
    N'SELECT * FROM dbo.Orders WHERE Id = @id',
    N'@id int',
    @id = 1;

-- PostgreSQL
SELECT * FROM orders WHERE id = $1;          -- libpq / prepared
PREPARE q(int) AS SELECT * FROM orders WHERE id = $1;
EXECUTE q(1);
-- Named (:id) là client (Npgsql, JDBC) — không phải parser server trừ dialect riêng
```

**Ghi chú:** Literal không `N` trên SQL Server CI/code-page có thể **mất ký tự Unicode** khi gán vào `nvarchar` — [literals.md](literals.md). PostgreSQL `'foo'` kiểu *unknown* đến khi neo — `PREPARE p AS SELECT $1` lỗi thiếu kiểu. SQL Server 2025: `sp_executesql` serialize compile (giảm compilation storm) — không đổi luật quoting; chi tiết routine: [routines.md](routines.md), kiến trúc plan cache: [internal.md](internal.md).

### 8.2 Dynamic SQL

```sql
-- SQL Server
DECLARE @sql nvarchar(max) =
    N'SELECT * FROM ' + QUOTENAME(@schema) + N'.' + QUOTENAME(@table);

-- PostgreSQL
EXECUTE format('SELECT * FROM %I.%I', schema_name, table_name);
```

`%I` / `QUOTENAME` quote identifier. `%L` / `quote_literal` quote literal. **Không** dùng `%s` cho tên bảng.

Trước (nguy hiểm):

```sql
-- ĐỪNG
EXECUTE 'SELECT * FROM ' || table_name;
```

Sau:

```sql
EXECUTE format('SELECT * FROM %I', table_name);
```

`QUOTENAME` mặc định ngoặc `[]`. Identifier chứa `]` được nhân đôi. Đừng `QUOTENAME` rồi còn bọc `[]` lần nữa.

---

## 9. Session SET

SQL Server: một cụm option phải `ON` cho indexed view, filtered index, computed persisted, XML index — nếu `OFF`, `CREATE INDEX` thất bại hoặc query không dùng index.

```sql
-- SQL Server: kiểm tra (bitmask @@OPTIONS)
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET ARITHABORT ON;                  -- thường đi cùng ANSI_WARNINGS
```

| Option | Tắt thì gì xảy ra |
|---|---|
| `QUOTED_IDENTIFIER OFF` | `"abc"` là *chuỗi*, không phải identifier |
| `ANSI_NULLS OFF` | `WHERE x = NULL` thành `IS NULL` — deprecated, phá indexed view |
| `CONCAT_NULL_YIELDS_NULL OFF` | `'a' + NULL` → `'a'` |
| `ANSI_WARNINGS OFF` | Overflow / chia 0 có thể thành `NULL` thay vì lỗi — phá index |
| `ARITHABORT OFF` | Cùng họ indexed view / compute |

PostgreSQL không có `ANSI_NULLS`. Có:

```sql
SET TIME ZONE 'Asia/Ho_Chi_Minh';
SET statement_timeout = '30s';
SET lock_timeout = '5s';
SET idle_in_transaction_session_timeout = '60s';
-- standard_conforming_strings: PG 19 luôn on — SET OFF lỗi / không còn
-- escape_string_warning: PG 19 gỡ — SET biến này lỗi
```

**Ghi chú:** ORM/driver (ADO.NET, JDBC, Npgsql) set option lúc connect. SSMS “script từ GUI” có thể khác app pool → “chạy được trên máy tôi”. `XACT_ABORT` / implicit txn: [transactions.md](transactions.md). `SET` trong stored proc SQL Server **dính theo object** lúc `CREATE` (`QUOTED_IDENTIFIER` / `ANSI_NULLS` lưu trên proc) — đổi session sau không sửa proc cũ.

Hai session — cùng proc, khác `CONCAT_NULL_YIELDS_NULL`:

```text
T1 (SSMS, ANSI ON):  SELECT 'a' + NULL;     -- NULL
T2 (legacy conn, OFF): SELECT 'a' + NULL;   -- 'a'
-- Unique / CHECK trên biểu thức nối: hai session khác hàng “trống”.
```

---

## 10. Compatibility, PREVIEW, protocol

### 10.1 Compat 170 vs PostgreSQL không compat

SQL Server **compatibility level** (160 = 2022, **170 = 2025**) quyết định optimizer / cardinality estimator / IQP mặc định (DOP feedback, Query Store secondary **ON**, CE expression, OPPO). **Không** khóa parser đầy đủ — engine 2025 vẫn parse nhiều cú pháp mới ở level 160; plan khi nâng 170 mới đổi.

PostgreSQL **không** có compat level. Major 19 = feature + **incompatibility cứng** (strings, JIT default, `json_array()`, FDW read-only). Nâng = `pg_upgrade` / dump, không “giữ 18 semantics trên binary 19”.

```sql
-- SQL Server: nâng engine ≠ nâng compat
ALTER DATABASE Sales SET COMPATIBILITY_LEVEL = 160;   -- đo Query Store
-- … baseline plan …
ALTER DATABASE Sales SET COMPATIBILITY_LEVEL = 170;
```

**Ghi chú:** Giữ 160 sau khi cài 2025 là runbook hợp lệ. Không có `SET compatibility_level` trên PostgreSQL — đừng bịa. Chi tiết IQP / Query Store: [internal.md](internal.md).

### 10.2 `PREVIEW_FEATURES`

```sql
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;  -- SQL Server 2025
```

Công tắc **database scoped**. Bật vector index / `VECTOR_SEARCH`, fuzzy string, Change Event Streaming, một số JSON on-prem. **Không** bật production trừ khi chấp nhận đổi theo CU.

Azure SQL một số JSON/vector đã GA trong khi on-prem còn **PREVIEW** — đừng copy runbook cloud. Bật “cho vector” kéo **cả** feature preview trên database đó, không phải từng lệnh.

PostgreSQL 19: không có flag tương đương. Cả major đang **beta** đến GA ~10/2026 — SQL/PGQ, `REPACK`, `WAIT FOR`, `FOR PORTION OF` có thể chỉnh trước GA.

### 10.3 `standard_conforming_strings` & `escape_string_warning`

PG **19**: `standard_conforming_strings` **luôn `on`**. Dump cũ với `SET standard_conforming_strings = off` **không load sạch**. Trong `'…'` thường, `\` là ký tự thường — [literals.md](literals.md).

`escape_string_warning` đã **gỡ**. Script `SET escape_string_warning = …` **lỗi** trên 19.

JIT **tắt mặc định** từ PG 19 (`jit = off`) — đây là GUC session/cluster, ảnh hưởng plan analytical, không phải identifier. Bật tay cho báo cáo lớn.

```sql
-- PostgreSQL 19: các lệnh sau fail hoặc vô nghĩa
-- SET standard_conforming_strings = off;
-- SET escape_string_warning = on;
SHOW standard_conforming_strings;     -- on, không tắt được
```

### 10.4 TDS 8 / TLS 1.3 — client breaking

SQL Server **2025**: protocol **TDS 8.0** + **TLS 1.3** trên engine, Agent, sqlcmd, bcp, PolyBase, **linked server**, replication, log shipping, CEIP, AG/FCI.

Đây là breaking **client / driver**, không đổi luật folding tên. Session “không connect được sau patch” thường là ODBC/JDBC/OLE DB cũ, không phải `SET`.

**Ghi chú:** Checklist dialect: test sqlcmd/bcp/linked server/replication **trước** cutover. PG 19: SNI server-side `PGDATA/pg_hosts.conf`; MD5 auth cảnh báo; RADIUS **gỡ**. Cùng họ “client cũ đứt”, khác stack — [internal.md](internal.md) §4, §18.

### 10.5 Edition / SKU chỉ khi đụng SET / identifier

Edition (Express 50 GB, Standard **32 core / 256 GB** buffer pool **2025**, Enterprise, Web **discontinued**, Developer tách Standard vs Enterprise) **không** đổi:

- folding identifier
- `sysname` 128
- `GO` vs `;`
- `QUOTED_IDENTIFIER` / `ANSI_NULLS`

SKU **có** đụng dialect khi:

- `SET` / hint đòi edition (`ONLINE = ON` rebuild historically Enterprise — kiểm Learn 2025).
- Resource Governor trên **Standard** 2025 (trước: EE) — `SET` workload group, tempdb governor lỗi **1138**.
- Staging “Developer” cũ = EE feature lọt Standard prod.

Chi tiết core/SKU/architecture: **[internal.md](internal.md) §19**. File này không lặp bảng edition.

---

## 11. Hai session — ví dụ làm việc

### 11.1 Folding tên khi port

```text
T1 (SQL Server):
  CREATE TABLE dbo.Orders (Id int NOT NULL);
  SELECT * FROM ORDERS;              -- OK, CI

T2 (PostgreSQL, cùng script unquoted):
  CREATE TABLE Orders (id int NOT NULL);   -- tạo "orders"
  SELECT * FROM "Orders";                  -- lỗi: không có "Orders"
  SELECT * FROM Orders;                    -- đọc "orders" — tình cờ OK
  CREATE TABLE "Orders" (id int NOT NULL); -- bảng thứ hai
```

Review: dump / ORM `quotedIdentifiers: true` lệch một phía = hai bảng.

### 11.2 `search_path` vs default schema

```text
T1 (PG, search_path = app, public):  INSERT INTO t VALUES (1);  -- app.t
T2 (PG, search_path = public, app):  SELECT * FROM t;           -- public.t, không thấy hàng T1
```

```text
T1 (SS, default schema app):  INSERT INTO T VALUES (1);         -- app.T
T2 (SS, default dbo):         SELECT * FROM T;                  -- dbo.T nếu tồn tại, else app? fallback dbo
```

Luôn schema-qualify trong app.

### 11.3 FDW read-only vs linked server

Đã ở §5.3. Thêm: SQL Server linked server sau TDS 8 — T2 không phải “lỗi SQL”, là lỗi handshake TLS. Phân biệt `Login failed` vs `SSL Provider`.

### 11.4 `PREVIEW_FEATURES` kéo theo database

```text
T1: ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;
    CREATE VECTOR INDEX … ;              -- PREVIEW, lab
T2: cùng DB, job CES / fuzzy cũng vào surface preview
    -- Tắt PREVIEW_FEATURES: object preview có thể fail / không tạo mới
```

Không có GUC PG tương đương; beta 19 là cả cluster.

---

## 12. Checklist nâng cấp (dialect / session)

Chỉ mục **parser / session / client / identifier**. Optimizer/HA/SKU đầy đủ: [internal.md](internal.md).

**SQL Server → 2025**

1. **Driver TDS 8 / TLS 1.3** (ODBC, JDBC, sqlcmd, bcp, linked server, replication, log shipping, PolyBase) — client cũ đứt sau patch, không phải `SET ANSI`.
2. **Nâng engine, giữ compat 160** đo Query Store — 170 đổi plan (DOP/OPPO), không đổi folding tên.
3. **Compat 170 khi ổn** — IQP mặc định ON; không giả “script cũ parse fail”.
4. **`PREVIEW_FEATURES` off production** — vector index / CES / fuzzy / nhiều JSON on-prem.
5. **So `SET` options app vs SSMS** — `QUOTED_IDENTIFIER` / `ANSI_NULLS` gắn proc; indexed view fail lúc deploy.
6. **Pool reset** — `#temp`, `SESSION_CONTEXT`, `USE` không leak request sau.
7. **SKU staging = prod** (Standard vs Enterprise Developer) — chỉ khi hint/`ONLINE`/RG; identifier không đổi.

**PostgreSQL → 19**

1. **`pg_dumpall` / `pg_upgrade` binary 19** — dump 18 `standard_conforming_strings=off` không restore; client cũ phá literal `\`.
2. **Gỡ script `SET escape_string_warning`** — biến đã xóa, SET lỗi.
3. **Tên DB/role/tablespace không CR/LF** — `pg_upgrade` từ chối.
4. **Đổi encoding `MULE_INTERNAL` trước** — encoding gỡ.
5. **Test `postgres_fdw` trong txn `READ ONLY`** — ghi remote fail; ETL phải txn read-write.
6. **`search_path` / `DISCARD ALL` trên pool** — không đổi so 18, nhưng custom GUC vẫn leak.
7. **JIT / `max_locks_per_transaction` 128** — GUC session/cluster; nhân đôi setting cũ nếu muốn cùng số lock. SQL/PGQ/`REPACK` = **beta**, không schema prod sớm.

---

## 13. Best practices & checklist

- Schema-qualify object trong app (`dbo.Orders` / `app.orders`); đừng dựa vào default schema / `search_path` cho bảo mật.
- Luôn `;`. Không nhúng `GO` vào script driver.
- Parameter cho giá trị; `QUOTENAME` / `format('%I')` cho identifier động.
- `IS NULL` / `IS DISTINCT FROM`, không `= NULL`.
- `CHECK` không thay `NOT NULL`.
- Collation / encoding: ghi rõ trong migration; test `'a' = 'A'` trên cả hai.
- `SET` ANSI_* `ON` trước filtered/computed index (SQL Server).
- Production: `PREVIEW_FEATURES` off; PG 19 graph/temporal chỉ sau GA + test.
- Connection pool: reset session (`search_path`, `#temp`, GUC) — đừng leak.
- Dump PG: client ≥ 19; không restore `standard_conforming_strings=off`.
- Linked server / sqlcmd: test TLS 1.3 trước cutover 2025.

---

## 14. Bẫy khi review

- Identifier copy SQL Server → PostgreSQL không quote → lower-case, trật bảng.
- `GO` trong file chạy bằng Dapper/Npgsql.
- `BEGIN` T-SQL bị hiểu là mở txn — [transactions.md](transactions.md), [keywords.md](keywords.md).
- `dbo` không tồn tại trên PostgreSQL.
- Cross-database 3-part name port sang PG như thể cùng statement.
- `WHERE col = NULL` “chạy không lỗi” nhưng zero row.
- `CHECK (status IN ('a','b'))` vẫn nhận `status` NULL.
- `QUOTED_IDENTIFIER OFF` trong stored proc cũ — index/computed fail lúc deploy.
- Dynamic SQL `'…' + @table` không `QUOTENAME`.
- So sánh chuỗi CI trên SQL Server, CS trên PG: unique `'A'`/`'a'` lệch.
- `TEMP` / `#temp` sống sót trên pooled connection.
- Dựa vào thứ tự cột `SELECT *` qua dialect/tool.
- `SET standard_conforming_strings = off` trong dump 18 lên PG 19.
- `SET escape_string_warning` trên PG 19.
- Newline trong tên role “cho đẹp” — chặn `pg_upgrade`.
- Compat 170 ngày cutover không baseline Query Store — [internal.md](internal.md).
- Bật `PREVIEW_FEATURES` “chỉ vector” kéo CES/fuzzy.
- Tưởng SKU Standard đổi luật identifier / `sysname`.
- FDW upsert trong `BEGIN READ ONLY` sau nâng 19.
- Client OLE DB cũ sau TDS 8 — “SQL lỗi” nhưng là handshake.

---

## 15. Version gates

| Mục | SQL Server | PostgreSQL |
|---|---|---|
| Compatibility 170 | **2025** | — (không có compat level) |
| `PREVIEW_FEATURES` | **2025** | — (cả 19 **beta**) |
| `FETCH` / `OFFSET` | 2012+ | lâu |
| `\|\|` nối chuỗi | **2022+** | lõi |
| `IS [NOT] DISTINCT FROM` | **2022+** | lõi; **19** fold `… NULL` |
| `DROP IF EXISTS` | 2016+ | lõi |
| `UNIQUE NULLS NOT DISTINCT` | — (filtered index) | **15+** |
| ICU nondeterministic collation | — (CI collation khác) | **15+** |
| `standard_conforming_strings` luôn on | — | **19** |
| `escape_string_warning` gỡ | — | **19** |
| JIT default off | — | **19** |
| `postgres_fdw` thừa READ ONLY | — | **19** |
| CR/LF cấm tên DB/role/tablespace | — | **19** |
| `MULE_INTERNAL` gỡ | — | **19** |
| TDS 8 / TLS 1.3 | **2025** (breaking client) | SNI `pg_hosts.conf` 19 |
| `#temp` / `##temp` | lõi | — (`CREATE TEMP`) |
| Resource Governor trên Standard | **2025** (SET/RG, không identifier) | — |

Kiểu dữ liệu: [typesystem.md](typesystem.md). Literal / escape: [literals.md](literals.md). Từ khóa reserved: [keywords.md](keywords.md). Process / SKU / WAL: [internal.md](internal.md).

---

## Phụ lục A. `@@OPTIONS` / GUC — soi session khi “chạy được trên máy tôi”

SQL Server: bitmask `@@OPTIONS` (không phải identifier). PostgreSQL: `SHOW ALL` / `current_setting`.

```sql
-- SQL Server
SELECT @@OPTIONS;
-- Bit QUOTED_IDENTIFIER, ANSI_NULLS, ANSI_WARNINGS, CONCAT_NULL_YIELDS_NULL, ARITHABORT, …
DBCC USEROPTIONS;                    -- SSMS: DATEFORMAT, language, isolation

-- PostgreSQL
SHOW standard_conforming_strings;    -- 19: on
SHOW search_path;
SHOW TimeZone;
SHOW statement_timeout;
-- SHOW escape_string_warning;       -- 19: lỗi — biến gỡ
```

Hai session — cùng login, khác client:

```text
T1 (SSMS): QUOTED_IDENTIFIER ON, language us_english, DATEFORMAT mdy
T2 (ADO pool): có thể ANSI_NULLS ON nhưng DATEFORMAT theo login default
T1 (psql): search_path "$user", public; TimeZone cluster
T2 (Npgsql): search_path từ connection string / Startup
```

Đừng soi một session rồi kết luận dialect “portable”. Driver TDS 8 không đổi bitmask; fail connect = không có `@@OPTIONS`.

**Ghi chú SKU:** Express/Standard không đổi `@@OPTIONS`. Resource Governor Standard 2025 đổi *workload* (`GROUP_MAX_TEMPDB_DATA_MB`) — lỗi 1138 — không phải parser identifier. Chi tiết: [internal.md](internal.md).

---

## Phụ lục B. Identifier CR/LF — query catalog trước `pg_upgrade`

```sql
-- PostgreSQL: tên chứa CR/LF (byte 13/10) — 19 từ chối upgrade
SELECT datname FROM pg_database
WHERE datname ~ E'\\r|\\n';
SELECT rolname FROM pg_roles
WHERE rolname ~ E'\\r|\\n';
SELECT spcname FROM pg_tablespace
WHERE spcname ~ E'\\r|\\n';
```

Pattern `E'\\r'` — escape-string, vì `'…'` 19 không unescape. Literal regex: [literals.md](literals.md).

SQL Server: soi `sys.databases.name` / logins có ký tự điều khiển hiếm; không `MULE_INTERNAL`. Encoding collation DB ≠ encoding cluster PG.

Hai session — tạo tên độc hại vs upgrade:

```text
T1 (PG 18): CREATE ROLE "app\nadmin";     -- có thể tạo (đừng)
T2 (pg_upgrade → 19): từ chối cluster cho đến khi đổi tên
```

`MULE_INTERNAL`: `SELECT datcollate, encoding FROM pg_database;` — đổi encoding **trước** đêm cutover, không SET session.
