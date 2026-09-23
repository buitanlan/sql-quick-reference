# Chỉ mục (Indexes)

> **Baseline:** SQL Server **2025** (17.x) · PostgreSQL **19**.  
> Index không “làm query nhanh”: nó đổi **access path**. Sai thứ tự cột, covering thiếu, hoặc index trên heap vs clustered khác nhau hai dialect — đây là nguồn plan regression khi port.

Index là cấu trúc phụ: seek/scan hẹp, uniqueness, join, covering. Mỗi index = chi phí ghi + dung lượng + maintenance. Hai engine cùng B-tree ở bề mặt nhưng lệch clustered/heap, `INCLUDE`, filtered/partial, columnstore (SQL Server), GIN/GiST/BRIN (PostgreSQL). `CREATE INDEX` không online/concurrent = schema lock ghi. JSON/vector index 2025 gắn **PREVIEW** trên on-prem SQL Server — đừng giả định GA (Azure một số JSON đã GA).

Sargable, join, khóa hàng: [select.md](select.md), [joins.md](joins.md), [concurrency.md](concurrency.md). Constraint unique/PK: [constraints.md](constraints.md). JSON path: [json.md](json.md). `REPACK` DDL: [ddl.md](ddl.md). Planner/stats kiến trúc: [internal.md](internal.md).

---

## Mục lục

- [1. Tổng quan \& triết lý](#1-tổng-quan--triết-lý)
- [2. B-tree: thứ tự cột](#2-b-tree-thứ-tự-cột)
- [3. Clustered vs heap vs CLUSTER / REPACK](#3-clustered-vs-heap-vs-cluster--repack)
- [4. Unique, covering, INCLUDE](#4-unique-covering-include)
- [5. Filtered / partial](#5-filtered--partial)
- [6. Expression / computed](#6-expression--computed)
- [7. Columnstore 2025 (ordered NCCI)](#7-columnstore-2025-ordered-ncci)
- [8. GIN / GiST / BRIN / HASH](#8-gin--gist--brin--hash)
- [9. JSON INDEX \& vector (PREVIEW)](#9-json-index--vector-preview)
- [10. Maintenance: REPACK vs REBUILD](#10-maintenance-repack-vs-rebuild)
- [11. Statistics, secondary, pg\_plan\_advice](#11-statistics-secondary-pg_plan_advice)
- [12. btree\_gist inet/cidr — chặn upgrade](#12-btree_gist-inetcidr--chặn-upgrade)
- [13. Worked examples](#13-worked-examples)
  - [13.6 pg\_plan\_advice](#136-pg_plan_advice--vòng-đời)
  - [13.7 Missing / duplicate index](#137-missing--duplicate-index)
  - [13.8 Delta store NCCI](#138-delta-store-ncci)
  - [13.9 CREATE INDEX CONCURRENTLY fail](#139-create-index-concurrently-fail)
- [14. Best practices \& checklist](#14-best-practices--checklist)
- [15. Bẫy khi review](#15-bẫy-khi-review)
- [16. Version gates](#16-version-gates)
- [Phụ lục A. Sargable](#phụ-lục-a-sargable--nhắc-nhanh)
- [Phụ lục B. Heap forwarding \& fillfactor](#phụ-lục-b-heap-forwarding--fillfactor)
- [Phụ lục C. Unused index](#phụ-lục-c-unused-index)
- [Phụ lục D. Vector index PREVIEW](#phụ-lục-d-vector-index-preview-vs-pgvector)
- [Phụ lục E. REPACK concurrent](#phụ-lục-e-repack-concurrent--slot)
- [Phụ lục F. Persisted stats secondary](#phụ-lục-f-persisted-stats-secondary--vận-hành)
- [Phụ lục G. Online build](#phụ-lục-g-online-build--khóa-từng-pha)
- [Phụ lục H. Checklist nâng index](#phụ-lục-h-checklist-nâng-index-why)

---

## 1. Tổng quan & triết lý

Optimizer chọn index khi predicate **sargable** (cột gốc so với hằng/tham số, không `YEAR(col)`, không `col + 0`) *và* thống kê nói selectivity đủ. Index “đúng cột” nhưng sai thứ tự vẫn scan.

Ba câu hỏi trước mỗi `CREATE INDEX`:

1. **Predicate nào?** Equality, range, `ORDER BY`, covering `SELECT` list.
2. **Ghi bao nhiêu?** OLTP nóng: ít index, hẹp. Analytics: columnstore / BRIN / covering rộng.
3. **Online được không?** Production: `ONLINE = ON` / `CONCURRENTLY` / `REPACK (CONCURRENTLY)` — không chặn ghi cả bảng.

PostgreSQL 19 **beta**: `REPACK`, parallel autovacuum, scoring, `pg_plan_advice`. SQL Server 2025: ordered NCCI **GA**; JSON index / vector index = **PREVIEW** trên on-prem.

```text
Access path (rút gọn)

SS clustered seek     = hàng nằm theo khóa CX, NCI lookup khóa CX
SS heap NCI           = RID; forwarding record sau UPDATE rộng
PG index scan         = TID → heap (trừ index-only + VM all-visible)
PG CLUSTER/REPACK     = sort một lần, insert sau phá thứ tự
```

---

## 2. B-tree: thứ tự cột

### 2.0 Hình dung: danh bạ, không phải “cột nào cũng được”

B-tree là danh bạ xếp theo **thứ tự khóa từ trái sang phải**. Tra “Nguyễn, Hà Nội” thì sách phải xếp *họ trước, thành phố sau*. Sách xếp *thành phố trước* không giúp nhảy tới họ Nguyễn — bạn phải lật mọi trang Hà Nội.

```text
Index (customer_id, created_at)

  customer 10, 2026-01
  customer 10, 2026-02     ← WHERE customer_id = 10 AND created_at >= '2026-02' nhảy đúng chỗ
  customer 11, 2026-01

Index (created_at, customer_id)

  2026-01, customer 10
  2026-01, customer 11     ← WHERE customer_id = 10 phải quét mọi ngày
```

**Sargable** = predicate để engine *nhảy* trong danh bạ, không tính lại từng dòng. `YEAR(created_at) = 2026` = “lấy năm của từng trang rồi mới so” — danh bạ vô dụng. Viết `created_at >= '2026-01-01' AND created_at < '2027-01-01'`. Hàm trên **cột** phá seek; hàm trên **hằng** (`WHERE created_at >= DATEADD(...)`) thường vẫn seek. Phụ lục A.

Mặc định cả hai engine: B-tree (SQL Server clustered/nonclustered; PostgreSQL `USING btree`).

```sql
-- SQL Server
CREATE INDEX ix_orders_customer_created
    ON dbo.Orders (CustomerId, CreatedAt DESC)
    WITH (ONLINE = ON);                          -- Enterprise / Developer tương ứng

-- PostgreSQL
CREATE INDEX CONCURRENTLY ix_orders_customer_created
    ON orders (customer_id, created_at DESC);
```

`CONCURRENTLY` / `ONLINE` **không** trong transaction block (PG). Fail giữa chừng PG: index `INVALID` — `DROP` rồi tạo lại. SS `ONLINE`: edition — Standard Developer **không** giả EE; kiểm SKU staging = prod.

### 2.1 Equality trước, range sau

Khóa `(a, b, c)` seek tốt khi predicate là `a = ?` rồi `b = ?` rồi range/`ORDER BY` trên `c`. Range sớm phá seek các cột sau.

```sql
-- WHERE customer_id = @id AND created_at >= @from
-- Tốt:  (customer_id, created_at)
-- Kém:  (created_at, customer_id)  — range created_at rồi mới lọc customer

-- WHERE a = @a AND b > @b ORDER BY c
-- Ứng viên: (a, b) hoặc (a, c) INCLUDE (b) tùy selectivity + sort
```

Cột equality **không** bắt buộc “selective nhất trước” nếu query luôn lọc `tenant_id` trước — đặt tenant đầu vì mọi câu đều có. Selective giúp histogram, không thay rule equality-then-range.

`DESC` trên khóa khớp `ORDER BY … DESC` tránh sort. Hai engine đều hỗ trợ chiều per-column.

### 2.2 Prefix & chồng index

`(a, b)` phục vụ `WHERE a = ?`. Index `(a)` thường **thừa** nếu `(a, b)` đã có — trừ khi `(a, b)` quá rộng, lookup đắt, hoặc uniqueness khác.

`(b, a)` **không** là prefix của `(a, b)`. Query chỉ `WHERE b = ?` không seek `(a, b)`.

**Ghi chú:** Duplicate index (cùng khóa, khác tên) = ghi đôi. Review `sys.indexes` / `pg_indexes` trước khi thêm “cho chắc”. `SELECT *` phá covering dù khóa đúng.

---

## 3. Clustered vs heap vs CLUSTER / REPACK

**Hình dung.** SQL Server clustered = sách **đóng gáy theo thứ tự khóa** và giữ thứ tự khi thêm trang. PostgreSQL heap = chồng giấy; index là mục lục “trang 17, dòng 3”. `CLUSTER` / `REPACK` chỉ **xếp lại một lần** — giấy mới sau đó lại chồng lộn.

**SQL Server:** tối đa **một** clustered index = thứ tự trang dữ liệu. Thường PK clustered. Không clustered = **heap**; nonclustered trỏ **RID**. Có clustered: nonclustered chứa khóa clustered (lookup). PK rộng (GUID, composite) làm mọi NCI phình.

```sql
CREATE CLUSTERED INDEX cx ON dbo.Orders (OrderId);     -- thường PK
-- Heap: không clustered. Lookup RID. Forwarding record sau UPDATE rộng.
```

Heap phù hợp staging/bulk; OLTP hầu hết nên có clustered hẹp, tăng dần (`int`/`bigint` identity), không random UUID làm clustered.

**PostgreSQL:** bảng là **heap**. Index trỏ TID. Không có “clustered index duy trì”. `CLUSTER` / `REPACK … USING INDEX` sắp xếp **một lần** — insert sau **không** giữ thứ tự.

```sql
CLUSTER orders USING orders_pkey;                       -- ACCESS EXCLUSIVE; cũ, vẫn chạy
REPACK orders USING INDEX orders_pkey;                  -- PG 19: thống nhất CLUSTER + VACUUM FULL
REPACK (CONCURRENTLY) orders USING INDEX orders_pkey;   -- exclusive chỉ lúc swap
```

Index-organized table (SQL Server clustered) ≠ `CLUSTER` PG. Đừng port “PK clustered” sang PostgreSQL rồi kỳ vọng heap luôn sorted.

**Ghi chú:** `REPACK` **19**, **beta**, không trong txn. Slot logical + `max_repack_replication_slots` khi `CONCURRENTLY`. Chi tiết [ddl.md](ddl.md) §10, mục 10 dưới.

---

## 4. Unique, covering, INCLUDE

```sql
CREATE UNIQUE INDEX ux_users_email ON users (email);

-- Covering: khóa seek + INCLUDE cột chiếu (không tham gia sort/uniqueness)
-- SQL Server
CREATE INDEX ix_orders_cover
    ON dbo.Orders (CustomerId)
    INCLUDE (Total, Status);

-- PostgreSQL (covering btree, 11+)
CREATE INDEX ix_orders_cover
    ON orders (customer_id)
    INCLUDE (total, status);
```

Index-only scan: query không đụng heap/clustered nếu mọi cột nằm khóa + INCLUDE. Cập nhật cột INCLUDE **vẫn** bảo trì index — INCLUDE không “miễn phí khi ghi”. PG: index-only cần visibility map all-visible — VACUUM / scan 19 đánh dấu all-visible; bloat + xmin horizon phá lợi ích.

Unique index = constraint unique (cả hai tạo unique index đứng sau PK/UNIQUE). NULL trong unique: [constraints.md](constraints.md).

SQL Server: unique filtered `WHERE col IS NOT NULL` ≈ cấm *nhiều hàng non-null trùng*, vẫn cho nhiều NULL trừ khi filtered `IS NOT NULL` (khi đó chỉ index hàng non-null → nhiều NULL được vì không vào index). Muốn một email NULL duy nhất: filtered unique **không** giới hạn số NULL.

**Ghi chú:** Covering rộng trên bảng OLTP = insert chậm. Đo `writes` vs `reads` trên `sys.dm_db_index_usage_stats` / `pg_stat_user_indexes`. Keyset pagination cần khóa khớp `ORDER BY` — [select.md](select.md).

---

## 5. Filtered / partial

```sql
-- SQL Server
CREATE INDEX ix_orders_open
    ON dbo.Orders (CustomerId, CreatedAt)
    WHERE Status = N'open';

-- PostgreSQL
CREATE INDEX ix_orders_open
    ON orders (customer_id, created_at)
    WHERE status = 'open';
```

Dùng khi predicate ổn định: `deleted_at IS NULL`, `status = 'open'`, `is_active = 1`. Unique partial: “email unique trong hàng chưa xóa”.

SQL Server: session tạo index phải `QUOTED_IDENTIFIER`, `ANSI_NULLS`, … ON. Predicate deterministic, không subquery. Parameterized query đôi khi **không match** filtered index (optimizer sợ NULL/`@status` không phải hằng) — `OPTION (RECOMPILE)` hoặc literal / `WHERE Status = N'open' AND …`.

PostgreSQL partial: planner match khi `WHERE` *implied* bởi predicate index (`status = 'open'` khớp; `status IN ('open','paid')` thường **không** dùng `status = 'open'`).

**Ghi chú:** Filtered/partial không thay partition. Thống kê trên filtered index SQL Server riêng — outdated stats → miss index.

---

## 6. Expression / computed

Query phải **khớp biểu thức** (hoặc cột computed) mới seek.

```sql
-- PostgreSQL
CREATE INDEX ix_users_email_lower ON users (lower(email));
CREATE INDEX ix_doc_status ON doc ((payload->>'status'));   -- jsonb → text

-- SQL Server: computed persisted rồi index (expression index trực tiếp hạn chế)
ALTER TABLE dbo.Users
    ADD EmailLower AS (LOWER(Email)) PERSISTED;
CREATE INDEX ix_users_email_lower ON dbo.Users (EmailLower);
```

`WHERE lower(email) = lower(@e)` dùng index PG. `WHERE email = @e` **không** dùng `lower(email)` trừ citext / collation case-insensitive.

SQL Server: `WHERE LOWER(Email) = …` trên cột gốc **không** dùng index `Email`. Phải lọc `EmailLower` hoặc computed match.

**Ghi chú:** Expression volatile (`now()`, `random()`) không index. PG: chỉ `IMMUTABLE`. Generated virtual (PG 18+) có thể index tùy phiên bản — test; extended stats trên virtual generated = **19**.

---

## 7. Columnstore 2025 (ordered NCCI)

SQL Server: columnstore cho analytics / HTAP. Clustered columnstore (CCI) = bảng dạng cột. Nonclustered columnstore (NCCI) = index phụ trên bảng rowstore (OLTP + báo cáo).

**2025 GA:**

- **Ordered NCCI** — `ORDER (col)` để segment elimination theo cột sort.
- Ordered columnstore (CCI và NCCI) **build/rebuild online** (`ONLINE = ON`, Enterprise / Developer tương ứng).
- Sort chất lượng hơn khi ordered CCI build online (spill `tempdb`; `MAXDOP = 1` → segment không chồng).
- Shrink (`DBCC SHRINKDATABASE` / `SHRINKFILE`) **di chuyển được** trang LOB của columnstore (trước đây kém).

```sql
CREATE CLUSTERED COLUMNSTORE INDEX cci ON dbo.FactSales;

CREATE NONCLUSTERED COLUMNSTORE INDEX ncci_orders
    ON dbo.Orders (CustomerId, Total, CreatedAt)
    ORDER (CreatedAt);                                 -- 2025 ordered NCCI

ALTER INDEX ncci_orders ON dbo.Orders
    REBUILD WITH (ONLINE = ON);                        -- 2025: ordered CS online
```

Khi nào ordered NCCI: HTAP — bảng rowstore OLTP + NCCI cho báo cáo range ngày. `ORDER (CreatedAt)` → segment elimination `WHERE CreatedAt >= @from`. Point lookup PK vẫn B-tree. Delta store + tuple mover trên NCCI nóng — đo insert.

Online rebuild ordered CS = EE/Developer tương ứng; Standard: kiểm Learn (`ONLINE` historically EE). `MAXDOP = 1` lúc build online ordered CCI → segment không chồng, I/O `tempdb` tăng — governor 1138 có thể đụng — [concurrency.md](concurrency.md). Shrink 2025 đẩy LOB CS: job shrink cũ có thể hiệu quả hơn, vẫn không chạy giờ cao điểm.

PostgreSQL **không** có columnstore native. Gần: BRIN (tương quan vật lý), partition, extension (Timescale, Citus), parquet FDW / `file_fdw`. Đừng bịa `CREATE COLUMNSTORE` trên PG.

**Ghi chú:** Ordered NCCI giúp range `CreatedAt`; không thay B-tree cho point lookup. Đo batch mode vs row mode. Compat 170 + IQP không tạo NCCI giúp bạn.

---

## 8. GIN / GiST / BRIN / HASH

PostgreSQL access method — SQL Server không có GIN/GiST/BRIN. XML / spatial / FTS / JSON index là loại riêng.

| Loại | Dùng cho |
|---|---|
| `btree` | Mặc định, `<` `≤` `=` `≥` `>` `BETWEEN` `ORDER BY` |
| `hash` | Chỉ `=`. WAL-logged từ PG 10; ít dùng hơn btree |
| `gin` | `jsonb`, array, FTS, một số `pgvector` opclass |
| `gist` | range, geometry (PostGIS), `EXCLUDE`, `btree_gist` |
| `brin` | Bảng lớn, cột tương quan vật lý (append-only time) |
| `spgist` | Cây không cân, một số kiểu |

```sql
CREATE INDEX ON posts USING gin (tags);
CREATE INDEX ON doc USING gin (payload jsonb_path_ops);   -- chỉ @>
CREATE INDEX ON events USING gist (during);
CREATE INDEX ON events USING brin (ts);
```

`jsonb_path_ops` nhỏ hơn `jsonb_ops`, **chỉ** containment `@>`. BRIN rẻ; sai khi update random phá correlation — lúc đó btree/`REPACK`.

SQL Server spatial / XML / full-text: không map 1-1 sang GiST/GIN. Vector: mục 9. `EXCLUDE` GiST: [constraints.md](constraints.md).

**Ghi chú:** `btree_gist` `inet`/`cidr` **hỏng** trên 19 — `pg_upgrade` **chặn**. Mục 12.

Extension C 19: `IndexAmRoutines` **static**; hook `get_relation_info_hook` → `build_simple_rel_hook` — rebuild AM tùy biến.

---

## 9. JSON INDEX & vector (PREVIEW)

### 9.1 JSON INDEX — on-prem PREVIEW

```sql
-- SQL Server 2025 — JSON INDEX: PREVIEW (on-prem). Cần clustered PK. Cột kiểu json.
CREATE JSON INDEX jix ON dbo.Doc (Payload);                    -- mặc định path $
CREATE JSON INDEX jix_paths ON dbo.Doc (Payload)
    FOR ('$.user.id', '$.status');                             -- path không chồng
```

Bảng phải có **clustered primary key**; không trên heap-only, indexed view, memory-optimized, computed json. Path `FOR` recursive từ node đó; `$.a` và `$.a.b` **lỗi** overlap (`$.user` gồm `$.user.id`). Tối ưu `JSON_VALUE` / `JSON_PATH_EXISTS` / `JSON_CONTAINS` (**PREVIEW** on-prem). Azure SQL / MI (policy 2025): kiểu `json` + nhiều hàm JSON **GA** trong khi on-prem còn preview — đừng copy runbook cloud.

Computed + btree trên `JSON_VALUE` vẫn valid trên `nvarchar` — không cần PREVIEW, không cần clustered PK *của JSON INDEX*. Chi tiết [json.md](json.md).

### 9.2 Vector index — PREVIEW_FEATURES

```sql
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;
CREATE VECTOR INDEX vix ON dbo.Doc (Embedding);    -- DiskANN, PREVIEW
-- VECTOR_SEARCH (ANN) — PREVIEW; catalog sys.vector_indexes
```

Kiểu `vector` + `VECTOR_DISTANCE` / `VECTOR_NORM` / `VECTORPROPERTY` là surface **GA** theo what's new 2025. **Index ANN và `VECTOR_SEARCH` = PREVIEW**. Hybrid = vector + full-text, không SQL/PGQ.

```sql
-- PostgreSQL
CREATE INDEX ON doc USING gin (payload);
CREATE INDEX ON doc USING gin (payload jsonb_path_ops);
CREATE INDEX ON doc ((payload->>'status'));

CREATE EXTENSION vector;                                       -- pgvector, không built-in
CREATE INDEX ON doc USING hnsw (embedding vector_cosine_ops);
CREATE INDEX ON doc USING ivfflat (embedding vector_l2_ops);
```

pgvector: `hnsw` / `ivfflat` — không copy operator `<->` sang T-SQL. `PREVIEW_FEATURES` là **database scoped**: bật “cho vector” kéo CES/fuzzy theo DB — [json.md](json.md) không chứa CES; CES: [concurrency.md](concurrency.md).

**Ghi chú:** Production on-prem: không bật `PREVIEW_FEATURES` trừ khi chấp nhận CU đổi. Expression btree trên `payload->>'status'` rẻ hơn GIN nếu chỉ equality một key. JSON INDEX không thay cột quan hệ + FK.

---

## 10. Maintenance: REPACK vs REBUILD

```sql
-- SQL Server
ALTER INDEX ix_orders_customer ON dbo.Orders REBUILD
    WITH (ONLINE = ON, MAXDOP = 4);
ALTER INDEX ix_orders_customer ON dbo.Orders REORGANIZE;
ALTER INDEX ALL ON dbo.Orders REBUILD;
UPDATE STATISTICS dbo.Orders;

-- PostgreSQL
REINDEX INDEX CONCURRENTLY ix_orders_customer;
VACUUM (ANALYZE) orders;
REPACK (CONCURRENTLY, ANALYZE) orders USING INDEX orders_pkey;  -- 19
-- Cũ, còn chạy:
VACUUM FULL orders;
CLUSTER orders USING orders_pkey;
```

| Mục đích | SQL Server | PostgreSQL |
|---|---|---|
| Compact / hết bloat vừa | `REORGANIZE` (leaf defrag) | `VACUUM` (không FULL) — FSM + freeze |
| Rebuild cây / hết frag nặng | `REBUILD` (`ONLINE`) | `REINDEX CONCURRENTLY` |
| Viết lại bảng + sort | rebuild clustered / `CREATE CX` | `REPACK` / `CLUSTER` |
| Không chặn ghi lâu | `ONLINE = ON` | `CONCURRENTLY` / `REPACK (CONCURRENTLY)` |

`REPACK` (19) thống nhất `VACUUM FULL` (compact heap) + `CLUSTER` (sort theo index). Lệnh cũ **còn chạy**.

```sql
REPACK employees;
REPACK (CONCURRENTLY, ANALYZE) employees USING INDEX employees_pkey;
REPACK (VERBOSE) employees;
```

Mặc định `ACCESS EXCLUSIVE` suốt copy. `CONCURRENTLY`: copy dưới `SHARE UPDATE EXCLUSIVE` + logical decoding vào stash; exclusive **lúc swap**. GUC `max_repack_replication_slots`. **Không** trong transaction block.

Hạn chế (**beta**): partitioned / unlogged / catalog; historically một concurrent repack một lúc; deadlock lock upgrade lúc swap — [concurrency.md](concurrency.md). Không thay `TRUNCATE`. Slot + WAL lúc concurrent — job đêm thử replica trước. Autovacuum song song **không** thay REPACK khi bloat nặng.

SS `REBUILD ONLINE` ≈ ý “không exclusive suốt copy”; **không** logical decoding. `REORGANIZE` ≠ `VACUUM` ≠ `REPACK`.

Fragmentation SS: rebuild khi external frag cao **và** nhiều page — bảng nhỏ đừng rebuild theo % mù. PG: bloat = dead tuple; `VACUUM` thường đủ.

`FILLFACTOR` / `fillfactor` chừa chỗ tránh split (SS) / page dày (PG). UUID random clustered/PK = split liên tục.

**Ghi chú:** Slot replication giữ xmin → vacuum không dọn — [concurrency.md](concurrency.md). `REPACK` không phải changelog: đó là rewrite heap.

---

## 11. Statistics, secondary, pg_plan_advice

Optimizer **đoán** cardinality từ histogram / density. Index đúng + stats sai = nested loop thảm họa.

```sql
-- SQL Server
UPDATE STATISTICS dbo.Orders WITH FULLSCAN;
CREATE STATISTICS st_orders_status ON dbo.Orders (Status);
DBCC SHOW_STATISTICS (N'dbo.Orders', ix_orders_customer);

-- PostgreSQL
ANALYZE orders;
CREATE STATISTICS st_orders (dependencies) ON customer_id, status FROM orders;
-- PG 19
SELECT pg_clear_extended_stats();           -- xóa extended stats
-- pg_restore_extended_stats khi restore dump 19
```

SQL Server auto-update theo ngưỡng sửa (% hàng; 2016+ incremental). Compat **170** đổi CE/IQP (DOP feedback **ON mặc định**, CE feedback **expression**, OPPO) — không thay index thiếu. Query Store secondary **ON mặc định** 2025.

### 11.1 Persisted statistics trên readable secondary (2025)

Trước 2025, secondary dùng stats “mang từ primary” hoặc tạo tạm. **2025 persist** stats trên secondary → plan báo cáo replica ổn hơn, **I/O ghi trên replica**. Kết hợp QS secondary ON: đo CPU/disk replica sau upgrade, không giả định “đọc thuần”.

RCSI trên primary không tự bật SI trên AG. Optimized locking per database — bật từng DB, test failover.

PostgreSQL: autovacuum `ANALYZE`. **19:** scoring thứ tự vacuum/analyze (`pg_stat_autovacuum_scores`, GUC `autovacuum_*_score_weight`); scan query có thể đánh dấu page **all-visible**; extended stats trên **virtual generated**; dump 19 restore được extended stats.

Standby PG **không** persist stats kiểu SS 2025 — `ANALYZE` trên primary, replica physical cùng file. Logical sub: stats local trên subscriber.

### 11.2 `pg_plan_advice` / `pg_stash_advice` (19, contrib)

Không phải hint T-SQL (`LOOP JOIN`, `FORCESEEK`). Module **contrib**:

- `pg_plan_advice`: mini-language mô tả join order / scan / parallel. `EXPLAIN (PLAN_ADVICE)` in chuỗi advice. GUC `pg_plan_advice.advice` áp chuỗi (session).
- `pg_stash_advice`: stash theo `(stash_name, queryId)` trong DSM; inject lúc plan. `pg_set_stashed_advice(...)`. `compute_query_id` cần on (`auto` khi load module). Persist file `pg_stash_advice.tsv` tùy GUC `pg_stash_advice.persist`.

Không bật mù như “hint SS cho mọi query”. `SET enable_hashjoin = off` vẫn dao debug. SS gần: Query Store force plan / `ABORT_QUERY_EXECUTION` — khác cơ chế.

**Ghi chú:** Parameter sniffing (SS) / generic vs custom plan (PG) không sửa bằng thêm index. Filtered index + sniff `@status` NULL: mục 5.

---

## 12. btree_gist inet/cidr — chặn upgrade

PG 19: opclass GiST mặc định cho `inet`/`cidr` đổi; index `btree_gist` trên `inet`/`cidr` **loại hàng sai**. `pg_upgrade` **từ chối** cluster còn index đó — không phải warning.

```text
Trước cutover 19:
  1. Tìm index gist btree_gist trên inet/cidr
  2. DROP INDEX (CONCURRENTLY nếu prod)
  3. pg_upgrade
  4. CREATE INDEX lại — opclass GiST mới (không btree_gist inet)
```

Giữ index đến đêm cutover = upgrade fail giữa giờ. `EXCLUDE` dùng `btree_gist` cho `int`/`uuid` + range **không** cùng bug inet — đừng drop hết `btree_gist`. Chỉ inet/cidr.

SQL Server không có `btree_gist`. Spatial index SS không map 1-1.

Incompatibility khác chặn dump/upgrade (strings, CR/LF tên, `MULE_INTERNAL`): [internal.md](internal.md) §20 — không nhét changelog vào file index.

---

## 13. Worked examples

### 13.1 OLTP — seek khách + covering

```sql
-- SQL Server
CREATE INDEX ix_orders_customer_created
    ON dbo.Orders (CustomerId, CreatedAt DESC)
    INCLUDE (Total, Status)
    WITH (ONLINE = ON);

-- PostgreSQL
CREATE INDEX CONCURRENTLY ix_orders_customer_created
    ON orders (customer_id, created_at DESC)
    INCLUDE (total, status);
```

Query `WHERE customer_id = $1 ORDER BY created_at DESC` + chiếu `total, status` → index-only (PG: VM).

### 13.2 Partial unique “email active”

```sql
-- SQL Server
CREATE UNIQUE INDEX ux_users_email_active
    ON dbo.Users (Email)
    WHERE DeletedAt IS NULL;

-- PostgreSQL
CREATE UNIQUE INDEX ux_users_email_active
    ON users (email)
    WHERE deleted_at IS NULL;
```

Hai hàng xóa mềm cùng email: được. Hai hàng active trùng: lỗi unique.

### 13.3 JSON path vs GIN vs JSON INDEX

```sql
-- SQL Server PREVIEW on-prem — clustered PK bắt buộc
CREATE JSON INDEX jix ON dbo.Doc (Payload) FOR ('$.status');

-- An toàn hơn khi chưa chấp nhận preview: computed
ALTER TABLE dbo.Doc
    ADD Status AS (JSON_VALUE(Payload, '$.status')) PERSISTED;
CREATE INDEX ix_doc_status ON dbo.Doc (Status);

-- PostgreSQL: equality một key → btree expression rẻ hơn GIN
CREATE INDEX ix_doc_status ON doc ((payload->>'status'));
```

### 13.4 Ordered NCCI range ngày

```sql
CREATE NONCLUSTERED COLUMNSTORE INDEX ncci_orders
    ON dbo.Orders (CustomerId, Total, CreatedAt)
    ORDER (CreatedAt);

-- Báo cáo: WHERE CreatedAt >= '2026-01-01' AND CreatedAt < '2026-02-01'
-- Segment elimination; OLTP insert vẫn rowstore + delta
```

### 13.5 REPACK vs REBUILD

```text
Bloat PG 40%, correlation ts hỏng BRIN
  → VACUUM thường: không sort lại heap
  → REINDEX: cây gọn, heap vẫn lộn
  → REPACK (CONCURRENTLY) USING INDEX … : heap sort + compact; slot/WAL
SS frag NCI 30% trên 200 page
  → đừng REBUILD; stats / query
SS NCCI ordered, segment chồng sau MAXDOP cao
  → REBUILD ONLINE MAXDOP 1 (EE), đo tempdb
```

### 13.6 `pg_plan_advice` — vòng đời

Docs contrib 19 (không bịa GUC ngoài module):

```sql
LOAD 'pg_plan_advice';
EXPLAIN (PLAN_ADVICE, VERBOSE) SELECT …
-- chuỗi advice + query id (VERBOSE)

SET pg_plan_advice.advice = '…';   -- session; chuỗi từ EXPLAIN hoặc tự viết subset
-- EXPLAIN không PLAN_ADVICE vẫn hiện advice đã áp (trừ always_explain_supplied_advice = false)
```

`pg_stash_advice`: `pg_set_stashed_advice(stash, query_id, advice)`; `SET pg_stash_advice.stash_name`. Query id đổi khi literal/constant — ORM ad-hoc phá stash. `compute_query_id` on. Persist `pg_stash_advice.tsv` khi `pg_stash_advice.persist` (start-only).

Không thay Query Store SS. Không copy chuỗi advice sang T-SQL.

### 13.7 Missing / duplicate index

```sql
-- SS: gợi ý missing (cân nhắc ghi) — không CREATE mù
SELECT * FROM sys.dm_db_missing_index_details;
-- Duplicate: cùng index_keys + filter + included
SELECT i.name, ic.*
FROM sys.indexes AS i
JOIN sys.index_columns AS ic
    ON ic.object_id = i.object_id AND ic.index_id = i.index_id
WHERE i.object_id = OBJECT_ID(N'dbo.Orders');
```

Hai index `(a)` và `(a,b)`: đo `user_seeks` trước khi drop `(a)`. Unique/PK/FK backing không drop dù scan = 0 trên replica.

PG: `pg_stat_user_indexes.idx_scan` + `pg_index.indisunique`. Extension `pg_qualstats` không core — đừng bịa vào runbook bắt buộc.

### 13.8 Delta store NCCI

Insert OLTP vào bảng có NCCI → **delta store** (rowgroup chưa nén) rồi tuple mover ép columnstore. Ordered NCCI 2025: segment elimination chỉ tốt trên group đã nén/sort. Đo `sys.column_store_row_groups` (OPEN vs COMPRESSED). Rebuild online ordered = EE; spill `tempdb` → 1138 nếu governor chặt.

CCI (clustered columnstore) không có B-tree clustered cùng lúc. Heap + NCCI ≠ CCI.

### 13.9 `CREATE INDEX CONCURRENTLY` fail

PG: index `INVALID` — query không dùng, ghi vẫn bảo trì. `DROP INDEX CONCURRENTLY` rồi tạo lại. Không `REINDEX` index invalid như tưởng xong. SS `ONLINE` fail: thường không để lại index “nửa”; kiểm job.

Hai pha CIC: (1) build, (2) validate — txn dài mở trước pha 2 chặn hoàn tất. Cùng họ `idle in transaction` với vacuum.

---

## 14. Best practices & checklist

- Equality cột lọc luôn có, rồi range/`ORDER BY`, rồi INCLUDE covering.
- Clustered SS hẹp, tăng dần. PG: đừng kỳ vọng heap sorted; `REPACK` khi correlation/BRIN cần.
- FK **phải** index — [constraints.md](constraints.md).
- Production: `ONLINE` / `CONCURRENTLY`; không `CREATE INDEX` chặn ghi giờ cao điểm. SKU `ONLINE`.
- Ít index trên bảng ghi nóng; periodic unused-index review.
- Columnstore cho scan analytics; B-tree cho point/OLTP. Ordered NCCI 2025 khi range date.
- Stats: `UPDATE STATISTICS` / `ANALYZE` sau bulk. Secondary 2025: đo persisted stats + QS I/O.
- JSON/vector index on-prem: **PREVIEW** — lab, không schema prod mặc định. Azure JSON có thể GA — đo từng môi trường.
- PG 19 `btree_gist` inet/cidr: gỡ trước upgrade.
- `pg_plan_advice`: contrib, ghim có chủ đích — không hint rải app.

---

## 15. Bẫy khi review

- `(created_at, customer_id)` cho `WHERE customer_id = ? AND created_at > ?`.
- Index `(a)` *và* `(a,b)` không đo usage — giữ cả hai “cho chắc”.
- `SELECT *` làm covering vô nghĩa.
- `LOWER(col)` / `YEAR(col)` trên cột gốc, không expression/computed khớp.
- Filtered SS + parameter — plan không dùng index; thiếu `RECOMPILE`.
- PK clustered UUID trên SS; mọi NCI phình + split.
- `CREATE INDEX` không `CONCURRENTLY`/`ONLINE` trên bảng live.
- Port clustered PK sang PG rồi tin `CLUSTER` duy trì.
- `VACUUM FULL` đêm thay vì `VACUUM` / `REPACK (CONCURRENTLY)` đã test.
- JSON INDEX path chồng (`$.a`, `$.a.b`); JSON INDEX trên heap.
- Vector index prod khi mới `PREVIEW_FEATURES` (kéo CES/fuzzy).
- `JSON_OBJECTAGG` / JSON INDEX prod on-prem như đã GA Azure.
- Rebuild 30% frag trên bảng 200 page.
- Giữ `btree_gist` inet đến cutover 19.
- Standard Developer test `ONLINE` rồi prod Standard.
- Stash advice quên `compute_query_id` / query id đổi vì literal.

---

## 16. Version gates

| Mục | SQL Server | PostgreSQL |
|---|---|---|
| Covering `INCLUDE` | lâu | 11+ btree |
| Partial / filtered | lâu | lâu |
| Ordered NCCI + CS online | **2025 GA** | — |
| JSON INDEX / `JSON_CONTAINS` | **2025 PREVIEW** on-prem; Azure JSON GA hơn | GIN `jsonb` |
| Kiểu `vector` + distance | **2025 GA** | pgvector ext |
| `CREATE VECTOR INDEX` / `VECTOR_SEARCH` | **2025 PREVIEW** | hnsw/ivfflat |
| Persisted stats secondary | **2025** | — (physical = file primary) |
| `REPACK` / `CONCURRENTLY` | `REBUILD ONLINE` | **19** (**beta**) |
| Extended stats virtual generated | — | **19** |
| `pg_stat_autovacuum_scores` | — | **19** |
| `pg_plan_advice` / `pg_stash_advice` | QS force plan | **19** contrib |
| `btree_gist` inet/cidr chặn upgrade | — | **19** |

Khóa khi build index, `SKIP LOCKED`: [concurrency.md](concurrency.md). Constraint unique/NULL: [constraints.md](constraints.md).

---

## Phụ lục A. Sargable — nhắc nhanh

```sql
-- Không sargable (cả hai)
WHERE YEAR(created_at) = 2026
WHERE LOWER(email) = N'ada@x.com'          -- trừ expression index / computed khớp
WHERE total + 0 = 10
WHERE CAST(customer_id AS varchar(10)) = '42'

-- Sargable
WHERE created_at >= '2026-01-01' AND created_at < '2027-01-01'
WHERE email = N'ada@x.com'                 -- collation CI
WHERE customer_id = 42
```

Hàm trên **cột** phá seek; hàm trên **hằng/tham số** thường ổn. JSON: `payload->>'status' = 'open'` cần expression index PG; SS: computed / JSON INDEX path. LIKE `'abc%'` thường seek; `'%abc'` không (trừ FTS/trigram).

**Ghi chú:** Implicit convert (SS: varchar vs nvarchar, PG: numeric vs text) có thể scan. Parameter sniffing không sửa bằng thêm index trùng.

---

## Phụ lục B. Heap forwarding & fillfactor

SQL Server heap: `UPDATE` rộng hơn chỗ → **forwarding record** (lookup 2 hop). `ALTER TABLE … REBUILD` / clustered hóa. PG: HOT update cùng page nếu fillfactor chừa chỗ và không đụng cột index; hết chỗ = heap mới + dead tuple.

`FILLFACTOR 90` (SS) / `fillfactor = 90` (PG) trên index/bảng ghi random. Clustered sequential: 100 (mặc định) thường đúng. UUID PK: fillfactor thấp không chữa split — đổi khóa.

---

## Phụ lục C. Unused index

```sql
-- SQL Server (reset khi restart instance — đọc cẩn thận)
SELECT i.name, s.user_seeks, s.user_scans, s.user_updates
FROM sys.dm_db_index_usage_stats AS s
JOIN sys.indexes AS i ON i.object_id = s.object_id AND i.index_id = s.index_id
WHERE s.database_id = DB_ID() AND i.object_id = OBJECT_ID(N'dbo.Orders');

-- PostgreSQL
SELECT indexrelid::regclass, idx_scan, idx_tup_read, idx_tup_fetch
FROM pg_stat_user_indexes
WHERE relid = 'orders'::regclass;
```

`idx_scan = 0` trên replica không chứng minh thừa trên primary. Unique/PK không drop. FK backing index: [constraints.md](constraints.md). Secondary 2025: usage stats / persisted stats = I/O riêng — đừng drop index “không dùng trên secondary”.

---

## Phụ lục D. Vector index PREVIEW vs pgvector

```sql
-- SS 2025: kiểu vector GA; index ANN PREVIEW
-- CREATE VECTOR INDEX …  (DiskANN); VECTOR_SEARCH
-- PREVIEW_FEATURES ON; catalog sys.vector_indexes
-- Hybrid = vector + full-text, không GRAPH_TABLE

-- PG: CREATE EXTENSION vector;
-- INDEX USING hnsw (embedding vector_cosine_ops)
-- INDEX USING ivfflat (embedding vector_l2_ops)
-- Operator <-> / <=> không có trên T-SQL (VECTOR_DISTANCE)
```

On-prem: không khóa schema ANN. Azure vector index có thể GA khác on-prem — đo. `PREVIEW_FEATURES` kéo CES/fuzzy theo database — [concurrency.md](concurrency.md) CES, [operators.md](operators.md) fuzzy (không nhét changelog vào đây).

IVFFLAT cần `ANALYZE` / lists phù hợp; HNSW RAM lúc build. Không `REPACK` thay rebuild HNSW. SS DiskANN: đọc Learn CU, không bịa WITH option.

---

## Phụ lục E. REPACK concurrent — slot

```text
REPACK (CONCURRENTLY)
  SHARE UPDATE EXCLUSIVE  → copy heap + logical decode DML vào stash
  ACCESS EXCLUSIVE        → swap file; deadlock upgrade nếu session khác nâng lock
  max_repack_replication_slots  → hết slot = fail, không “giống VACUUM”
Không trong BEGIN. Partitioned/unlogged/catalog: docs beta — có thể cấm.
Sau swap: ANALYZE nếu không (ANALYZE) trong lệnh. Autovacuum scoring không thay REPACK.
```

SS `REBUILD ONLINE` không tạo replication slot. So sánh “online” chỉ ở *không exclusive suốt copy*.

---

## Phụ lục F. Persisted stats secondary — vận hành

```text
AG readable secondary 2025
  Query Store ON mặc định trên secondary
  Stats persist trên replica → ghi I/O (không “đọc thuần”)
  Plan báo cáo ổn hơn “stats mang từ primary”
Đo: disk/CPU replica sau upgrade, không chỉ primary
Failover: stats local replica — test plan sau failover
Không: RCSI primary tự bật SI secondary
Không: optimized locking “theo AG” — per database, test từng DB
```

PG physical standby: cùng file stats với primary (không persist riêng). Logical subscriber: `ANALYZE` local. `WAIT FOR` không cập nhật stats.

### Histogram lệch

SS `DBCC SHOW_STATISTICS`; PG `pg_stats`. Filtered index SS: stats riêng — `@status` sniff NULL miss index (mục 5). Extended stats PG 19 trên **virtual generated**; `pg_clear_extended_stats()` xóa; dump 19 restore extended.

Parameter sniffing ≠ thiếu index. OPPO/PSPO 2025 tăng plan cache — đo, không thêm NCI “cho mọi `@p`”.

---

## Phụ lục G. Online build — khóa từng pha

```text
SS ONLINE
  Sch-S ngắn → copy → Sch-M ngắn lúc cuối
  Edition: EE / Enterprise Developer; Standard historically không ONLINE
  Ordered CS ONLINE + MAXDOP 1: tempdb; 1138

PG CONCURRENTLY / REPACK CONCURRENTLY
  Không trong txn
  CIC: INVALID nếu fail giữa chừng
  REPACK: SUE copy + AE swap; slot logical
Txn dài (idle in transaction) chặn pha cuối cả hai máy
```

`CREATE INDEX` chặn ghi (PG `SHARE`) trên bảng live = incident. Review PR: bắt `CONCURRENTLY`/`ONLINE`.

btree_gist inet: gỡ **trước** `pg_upgrade` — không phải job REPACK đêm cutover. Ordered NCCI: `ORDER (CreatedAt)` cho range; point PK vẫn B-tree. JSON INDEX PREVIEW: clustered PK, path không chồng, on-prem ≠ Azure GA.

`pg_plan_advice` / `pg_stash_advice` = contrib 19, query id + `EXPLAIN (PLAN_ADVICE)`. Không hint T-SQL. Stash DSM; `compute_query_id`. Vector ANN DiskANN PREVIEW; pgvector hnsw/ivfflat GA extension — không copy `<->`.

Fillfactor UUID clustered không chữa split. Covering INCLUDE vẫn ghi khi cột INCLUDE đổi. BRIN cần correlation; `REPACK USING INDEX` nếu heap lộn.

Missing index DMV SS gợi ý — cân nhắc ghi trước khi CREATE. Duplicate `(a)` và `(a,b)`: đo seeks. `CREATE INDEX CONCURRENTLY` fail → `INVALID`, DROP CONCURRENTLY rồi tạo lại. Ordered NCCI delta store: segment elimination trên group nén.

Persisted stats secondary 2025 = I/O ghi replica + Query Store secondary ON mặc định. `btree_gist` inet/cidr: `pg_upgrade` **chặn**. JSON INDEX / `CREATE VECTOR INDEX` = PREVIEW on-prem. `REPACK` 19 ≠ `REBUILD` ≠ `REORGANIZE` ≠ `VACUUM`.

---

## Phụ lục H. Checklist nâng index (WHY)

1. **Gỡ `btree_gist` inet/cidr trước `pg_upgrade`** — upgrade **chặn**, không warning.
2. **JSON/vector INDEX chỉ lab on-prem** — PREVIEW; Azure JSON có thể GA lệch.
3. **Ordered NCCI cho range ngày** — không thay B-tree PK; đo delta store.
4. **REPACK (CONCURRENTLY) đo slot/WAL** — không thay VACUUM thường.
5. **Persisted stats secondary** — I/O ghi replica + QS ON mặc định.
6. **`pg_plan_advice` contrib** — ghim có chủ đích, không hint rải app.
7. **ONLINE / CONCURRENTLY** — SKU EE; CIC INVALID phải DROP.
8. **FK backing index** — không drop dù `idx_scan = 0` trên replica.

