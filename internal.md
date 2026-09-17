# Kiến trúc nội bộ — giống và khác

> **Baseline:** SQL Server **2025** (17.x) · PostgreSQL **19**.  
> File này so sánh **engine**, không phải cú pháp. Isolation: [transactions.md](transactions.md). Khóa: [concurrency.md](concurrency.md). Index/storage: [indexes.md](indexes.md). DDL vật lý: [ddl.md](ddl.md). JSON binary: [json.md](json.md). Constraint: [constraints.md](constraints.md).

Hai sản phẩm cùng nói “SQL”, cùng có page, WAL/log, buffer, statistics, replica — nhưng **không cùng máy**. Port schema rồi đo QPS mà không hiểu process model, visibility, vacuum vs ghost cleanup, tempdb vs `pgsql_tmp` là đoán mò. Mục tiêu: biết chỗ **cùng ý** (để chuyển khái niệm) và chỗ **cùng tên nhưng khác guarantee** (để không copy runbook).

Delta phiên bản (TDS 8, `WAIT FOR`, optimized locking, …) gom **§20** — các mục 3–16 là kiến trúc bền, không changelog.

---

## Mục lục

- [1. Tổng quan \& triết lý](#1-tổng-quan--triết-lý)
- [2. Bảng ánh xạ nhanh](#2-bảng-ánh-xạ-nhanh)
- [3. Process \& memory](#3-process--memory)
  - [3.4 Shared memory vs clerk](#34-shared-memory-vs-clerk)
  - [3.5 NUMA và I/O worker](#35-numa-và-io-worker)
- [4. Kết nối, session, protocol](#4-kết-nối-session-protocol)
- [5. Catalog \& database](#5-catalog--database)
- [6. Storage: file, page, heap](#6-storage-file-page-heap)
- [7. TOAST vs LOB](#7-toast-vs-lob)
- [8. WAL vs transaction log](#8-wal-vs-transaction-log)
  - [8.1 Full page write vs VLF](#81-full-page-write-vs-vlf)
  - [8.2 Delayed durability](#82-delayed-durability-vs-synchronous_commitoff)
  - [8.3 Logical decode giữ xmin](#83-logical-decode-giữ-xmin)
- [9. Buffer, checkpoint, dirty page](#9-buffer-checkpoint-dirty-page)
- [10. Visibility: MVCC vs lock + version](#10-visibility-mvcc-vs-lock--version)
  - [10.1 Snapshot xmin vs version store](#101-snapshot-xmin-vs-version-store-size)
  - [10.2 HOT vs in-place](#102-hot-vs-in-place)
- [11. Dọn rác: vacuum vs ghost / ADR](#11-dọn-rác-vacuum-vs-ghost--adr)
- [12. Temp: tempdb vs pgsql\_tmp](#12-temp-tempdb-vs-pgsql_tmp)
- [13. Optimizer \& statistics](#13-optimizer--statistics)
- [14. Parallelism](#14-parallelism)
- [15. HA \& replication](#15-ha--replication)
  - [15.4 Crash recovery](#154-crash-recovery--hai-máy)
  - [15.5 Connection storm](#155-connection-storm)
  - [15.6 Redo vs đọc replica](#156-redo-vs-đọc-replica)
- [16. Backup \& restore](#16-backup--restore)
- [17. Extensibility](#17-extensibility)
- [18. Bảo mật engine](#18-bảo-mật-engine)
- [19. Edition, compat, GUC](#19-edition-compat-guc)
- [20. Điểm 2025 / 19 trên kiến trúc](#20-điểm-2025--19-trên-kiến-trúc)
- [21. Chọn engine khi nào](#21-chọn-engine-khi-nào)
- [22. Best practices \& checklist](#22-best-practices--checklist)
- [23. Bẫy khi review](#23-bẫy-khi-review)
- [24. Version gates](#24-version-gates)
- [Phụ lục A. Incident map](#phụ-lục-a-incident-map--đúng-máy)
- [Phụ lục B. Recovery window](#phụ-lục-b-sơ-đồ-recovery-window)
- [Phụ lục C. ctid / RID](#phụ-lục-c-ctid--rid-không-ổn-định)
- [Phụ lục D. Buffer vs OS cache](#phụ-lục-d-buffer-pool-vs-os-cache--đo)
- [Phụ lục E. Autovacuum parallel](#phụ-lục-e-autovacuum-parallel-vs-oltp)
- [Phụ lục F. Checklist kiến trúc](#phụ-lục-f-checklist-kiến-trúc-why)

---

## 1. Tổng quan & triết lý

Cùng bài toán: bền vững sau crash, cô lập người đọc/người ghi, plan query, nhân bản. Khác **hợp đồng**:

| Trục | SQL Server | PostgreSQL |
|---|---|---|
| Đơn vị chạy | Một process, nhiều thread (Windows/Linux) | Một postmaster + **process** (hoặc thread trên bản build thread) per backend |
| Cập nhật hàng | Thường **in-place** + log + (tùy) version store | **Không** in-place: tuple mới + `xmax` trên bản cũ (MVCC) |
| Reader mặc định | S lock (trừ RCSI) | Không row-lock trên `SELECT` thường |
| Dọn bản cũ | Ghost cleanup / version store / ADR | `VACUUM` / autovacuum / `REPACK` |
| Nhiều database | Instance chứa nhiều DB, query 3-part | Một cluster, **một connection = một DB** |
| Mở rộng | CLR, PolyBase, external model | Extension C / SQL (`pgvector`, FDW) |
| Nâng major | In-place + **compat level** | `pg_upgrade` / dump — **không** compat level |

“Giống” ở mức sơ đồ hộp: client → protocol → parser → rewriter → planner → executor → buffer → disk. “Khác” ở mọi hộp con: TDS ≠ libpq, CE ≠ cost model, `tempdb` ≠ local temp files, AG ≠ streaming + slot.

Đừng giải thích PostgreSQL bằng thuật ngữ SQL Server (`tempdb`, `NOLOCK`, `clustered index` = thứ tự vật lý mãi) và ngược lại (`VACUUM` không phải `REORGANIZE`).

---

## 2. Bảng ánh xạ nhanh

| Ý | SQL Server | PostgreSQL | Cùng? |
|---|---|---|---|
| Instance / cluster | Instance | Cluster (`PGDATA`) | Gần: một bộ nhớ + catalog |
| Database | Database trong instance | Database trong cluster | **Khác:** SS query cross-DB; PG không |
| Schema | Schema (`dbo`) | Schema + `search_path` | Gần |
| Page | 8 KB (có thể 2–64 KB historically; 8 KB chuẩn) | 8 KB mặc định | Gần |
| Extent | 8 page | Không cùng khái niệm | Khác |
| Filegroup | Filegroup | Tablespace | Gần (đặt file) |
| Heap | Heap (không clustered) | Heap (mặc định mọi bảng) | **Khác:** SS thường clustered PK |
| Clustered index | Thứ tự vật lý **duy trì** | `CLUSTER` / `REPACK` **một lần** | **Không** cùng |
| Transaction log | `.ldf` + VLFs | WAL (`pg_wal`) | Gần vai trò, khác format |
| Checkpoint | Checkpoint | Checkpoint | Gần |
| Buffer pool | Buffer pool | `shared_buffers` + OS cache | **Khác:** PG dựa page cache OS nhiều hơn |
| Temp | `tempdb` (DB thật) | Temp files + temp tables trong `pg_temp` | **Khác** |
| Version cũ | Version store (`tempdb`/ADR) khi RCSI/SI | Tuple trên heap + xmax | Khác chỗ để |
| Statistics | `sys.stats` / histogram | `pg_statistic` / `ANALYZE` | Gần |
| Plan cache | Plan cache + sniffing | Prepared generic/custom | Gần ý, khác cơ chế |
| Replica | AG, FCI, log shipping | Streaming, logical, Patroni… | Khác sản phẩm |
| Logical decode | CDC / CES **PREVIEW** | Logical replication / decoding | Gần ý |
| Full-text | Full-text catalog | `tsvector` / GIN | Khác |
| Vector | Kiểu `vector` native 2025 | `pgvector` extension | Gần API, khác ship |

---

## 3. Process & memory

### 3.1 SQL Server — một process, nhiều scheduler

Một process `sqlservr`. SQLOS: scheduler theo CPU/NUMA, worker thread lấy task từ queue. Fiber / lightweight pooling **deprecated** 2025. Memory clerk: buffer pool, plan cache, lock manager, query grant (`memory grant`). `max server memory`, lock pages in memory.

```text
                    ┌────────── sqlservr (một process) ──────────┐
 Client TDS ──►     │  Network  →  Task  →  Worker (thread)      │
                    │       │                                    │
                    │   Scheduler 0   Scheduler 1   …  (NUMA)    │
                    │       │                                    │
                    │   Buffer pool │ Plan cache │ Lock mgr      │
                    └────────────────────────────────────────────┘
 Crash process = cả instance. THREADPOOL wait = hết worker.
```

Hệ quả vận hành:

- Crash process = cả instance (kể mọi database).
- Thread starvation / `THREADPOOL` wait khi connection + song song quá.
- `max worker threads` và `cost threshold for parallelism` là núm thật.
- Memory grant quá lớn → `RESOURCE_SEMAPHORE`; quá nhỏ → spill `tempdb`.

**Kịch bản:** 4 000 connection + `MAXDOP 8` + CXPACKET. Worker không đủ → login mới đợi `THREADPOOL`, query đang chạy không “chậm SQL” mà hết thread. Sửa: pool, giảm DOP, không tăng connection mù.

### 3.2 PostgreSQL — postmaster + backend

`postmaster` (hoặc `postgres` supervisor) spawn **backend process** mỗi connection (mặc định process mode). Process phụ: `checkpointer`, `background writer`, `walwriter`, `autovacuum launcher` + worker, `logical replication` launcher, I/O workers (18+/19 scale).

```text
                    postmaster
                         │
     ┌───────────┬───────┼────────┬────────────┐
 checkpointer  bgwriter  walwriter  av launcher │
                                              backends
                         │                      │
                    shared_buffers          backend 1 (conn A)
                    WAL buffers             backend 2 (conn B)
                    proc array / locks      … max_connections
                         │
                    OS page cache (đọc thường xuyên hơn SS)
```

Hệ quả:

- Một backend crash thường không kéo cả cluster (còn lại reset shared memory theo rule).
- `max_connections` đắt: mỗi backend ~ vài MB. Connection pool (`PgBouncer`) gần như bắt buộc ở quy mô web.
- `shared_buffers` (thường 25% RAM) + **page cache OS**. `effective_cache_size` chỉ gợi ý planner, không cấp phát.

**Kịch bản:** `max_connections=2000` không pool → RAM OOM / context switch. PgBouncer transaction pool: `SET` / prepared / session advisory lock **vỡ** — pool session mode cho connection giữ state.

### 3.3 Ghi chú

SQL Server “một vòng đời memory” trong process. PostgreSQL “nhiều process, SysV/POSIX shm”. So `SET max server memory` với `shared_buffers` 1-1 là sai — PG còn OS cache.

PG 19: `io_min_workers` / `io_max_workers` tự scale I/O worker. SQL Server 2025: I/O vẫn trong SQLOS + parallel redo AG. Build PG thread-mode (nếu distro bật) đổi mô hình “một process một conn” — đối chiếu build, đừng giả định mọi 19 đều process.

### 3.4 Shared memory vs clerk

```text
PGDATA lúc chạy
  shared_buffers     : trang bảng/index (một phần)
  wal_buffers        : WAL trước flush
  proc array         : snapshot xmin
  lock table         : max_connections × max_locks_per_transaction (19: 128)
  autovacuum work    : không “clerk” kiểu SS

sqlservr
  buffer pool clerk  : trang
  lock manager       : khóa (optimized locking giảm số KEY giữ)
  plan cache         : sniffing / OPPO 2025 nhiều plan hơn
  memory grant       : sort/hash — hết → RESOURCE_SEMAPHORE
```

Đo PG: `pg_backend_memory_contexts` / `pg_dsm_registry_allocations` (19). SS: `sys.dm_os_memory_clerks`. So 1-1 clerk vs GUC là sai.

### 3.5 NUMA và I/O worker

SS: scheduler per NUMA node; foreign page tốn. PG 19: I/O worker `io_min_workers` / `io_max_workers` / `io_worker_idle_timeout` / `io_worker_launch_interval` — scale theo tải, không một con số cố định. SS 2025 I/O vẫn SQLOS; AG parallel redo không phải “io_workers GUC”.

**Kịch bản:** Tăng `shared_buffers` 80% RAM trên PG → OS cache bị ép, double buffering kém, checkpoint spike. 25% + OS cache thường đúng hơn copy `max server memory`.

---

## 4. Kết nối, session, protocol

| | SQL Server | PostgreSQL |
|---|---|---|
| Protocol | **TDS** (2025: TDS **8.0** + TLS 1.3) | **Frontend/Backend** (libpq) |
| Port mặc định | 1433 | 5432 |
| Auth | SQL login, Windows, Entra, cert | `pg_hba.conf`: scram, cert, peer, LDAP, OAuth… |
| Session | `SET` + context_info / session_context | `SET` / `SET LOCAL` + GUC |
| Batch | Client `GO`; nhiều statement / RPC | Nhiều statement trong simple query; extended query = parse/bind/execute |

**Ghi chú:** TDS 8 **breaking** client cũ — driver ODBC/JDBC/linked server phải mới. PG 19: `standard_conforming_strings` luôn on; SNI server-side `pg_hosts.conf`. Password MD5 cảnh báo; RADIUS gỡ.

Prepared statement: SQL Server `sp_prepare` / `sp_executesql` (2025 serialize compile — [routines.md](routines.md)). PostgreSQL `PREPARE` / unnamed extended query; generic vs custom plan (`plan_cache_mode`).

**Kịch bản:** Nâng SS 2025, Agent + linked server + `bcp` cũ → TLS handshake fail. Không phải “query chậm”. PG: client dump 18 `standard_conforming_strings=off` restore 19 lệch escape — §20.

---

## 5. Catalog & database

### 5.1 SQL Server: instance ⊃ database ⊃ schema ⊃ object

`sys.objects`, `sys.indexes` **theo database**. Query `OtherDb.dbo.T` trong cùng statement. Collation có thể khác từng DB — join cross-db dễ implicit convert.

Recovery model, filegroup, compat level (**170** = 2025) là thuộc tính **database**. Nâng engine ≠ nâng compat.

### 5.2 PostgreSQL: cluster ⊃ database ⊃ schema

`pg_class`, `pg_attribute` trong từng database (shared catalog: role, tablespace). Connection `dbname=` cố định; đổi DB = connection mới. Cross-database: `postgres_fdw` / dblink.

`search_path` quyết định `t` là schema nào — [dialects.md](dialects.md). `public` không thiêng. FDW 19 thừa `READ ONLY` — [transactions.md](transactions.md) §12.

### 5.3 System column

PostgreSQL: `xmin`, `xmax`, `ctid`, `cmin`/`cmax` trên **mọi** heap tuple. `SELECT xmin FROM t` hợp lệ. `ctid` = vị trí vật lý — đổi sau `VACUUM FULL`/`REPACK`.

SQL Server: `%%physloc%%` (undocumented-ish), `rowversion`, `%%lockres%%`. Không có `xmin` công khai tương đương. RID heap vs khóa clustered key trong nonclustered.

---

## 6. Storage: file, page, heap

### 6.1 Page

Cả hai: page ~8 KB, header + item identifier + tuple. Fill factor / `fillfactor` chừa chỗ update.

SQL Server: page thuộc extent (mixed/uniform), GAM/SGAM/PFS/IAM. Allocation bitmap quyết định “trang nào trống”.

PostgreSQL: FSM (free space map), VM (visibility map). VM đánh dấu all-visible → index-only scan bỏ heap. PG 19: **scan query** có thể đánh dấu all-visible (trước: VACUUM / `COPY FREEZE`).

```text
Page 8 KB (cả hai, rút gọn)
┌──────── header ────────┬── item ids ──┬──── tuples (từ cuối) ────┐
│ LSN, checksum, …       │  off,len,…   │  [row] [row]   free     │
└────────────────────────┴──────────────┴─────────────────────────┘
```

### 6.2 Bảng vật lý

**SQL Server:** chọn heap **hoặc** một clustered index (thường PK). Nonclustered trỏ RID (heap) hoặc clustered key. Đổi PK clustered = rebuild bảng.

**PostgreSQL:** bảng = heap + index riêng. PK = unique btree, **không** reorder heap. `CLUSTER` / `REPACK … USING INDEX` sort một lần — insert sau **không** giữ thứ tự.

Hệ quả: “clustered index seek” trên SS là access path chính. Trên PG, “index scan + heap fetch” — correlation vật lý (`CLUSTER`, BRIN) quyết định rẻ hay đắt. Chi tiết [indexes.md](indexes.md).

### 6.3 File

SQL Server: `.mdf`/`.ndf` + `.ldf`; filegroup; `tempdb` nhiều file. Instant file initialization (quyền SeManageVolume).

PostgreSQL: `PGDATA/base/<oid>/`, WAL `pg_wal`, tablespace ngoài. Không “một file một bảng” trừ khi bạn nghĩ thế — mỗi fork (`_fsm`, `_vm`, TOAST) là file.

---

## 7. TOAST vs LOB

Giá trị lớn không nằm nguyên 8 KB.

**PostgreSQL TOAST:** bảng toast riêng, nén (`pglz` / **`lz4` mặc định 19**), out-of-line. `bytea`/`jsonb`/`text` dài. `default_toast_compression`.

**SQL Server:** `varchar(max)` / `varbinary(max)` / `nvarchar(max)` in-row đến ngưỡng rồi LOB page (`text/image` cũ deprecated). `json` 2025 binary ~2 GB/row (**PREVIEW** on-prem). Columnstore có LOB riêng; 2025 shrink CS cải thiện.

Cập nhật một key JSON lớn = rewrite giá trị (cả hai, trừ patch nhỏ khi engine hỗ trợ — `json.modify` PREVIEW). Chi tiết [json.md](json.md).

---

## 8. WAL vs transaction log

Cùng ý: ghi redo **trước** (hoặc theo rule) để crash recovery.

```text
PostgreSQL (rút gọn)

  backend ──► WAL buffers ──► walwriter / commit flush ──► pg_wal/*.wal
                  │
                  ▼
            shared_buffers (dirty) ──► checkpointer / bgwriter ──► heap files

  COMMIT (synchronous_commit=on): flush WAL đến LSN commit *trước* trả client.
  Crash: replay WAL từ redo pointer (checkpoint) → heap bắt kịp log.

SQL Server (rút gọn)

  worker ──► log cache ──► flush .ldf (VLF) ──► COMMIT trả
                  │
                  ▼
            buffer pool dirty ──► checkpoint / lazy writer ──► .mdf/.ndf

  FULL recovery: backup log mới truncate VLF (trừ log reuse wait).
```

| | SQL Server | PostgreSQL |
|---|---|---|
| Tên | Transaction log (`.ldf`) | WAL (`pg_wal`) |
| Đơn vị | VLF, log record | Segment 16 MB (mặc định), LSN |
| Truncate | Backup log (FULL) / checkpoint (SIMPLE) | Checkpoint + archive / slot giữ |
| Sync | `COMMIT` flush (trừ delayed durability) | `synchronous_commit` (off/local/remote_*) |
| Nén backup | Backup compression / **ZSTD 2025** | `pg_basebackup` nén; WAL gzip/lz4/zstd |

Slot logical / CES / mirroring **giữ** log không truncate — đầy đĩa. PG: replication slot + `retain_dead_tuples`. SS: CDC/CES/mirroring `log_reuse_wait_desc`. Chi tiết [concurrency.md](concurrency.md) §11.

PG 19: `WAIT FOR LSN` trên standby — [transactions.md](transactions.md) §11. SS: không có lệnh tương đương; sync AG commit hoặc retry đọc replica.

**Kịch bản WAL đầy:** slot chết `restart_lsn` đứng yên → `pg_wal` phình → instance read-only / crash. SS: CES consumer lag → `log_reuse_wait` → `.ldf` phình. Cùng *ý*, hai catalog.

LSN không timeline trên `WAIT FOR` (docs 19) — cascade promote: số LSN trùng timeline khác có thể `success` giả. App DR phải biết timeline, không chỉ số.

### 8.1 Full page write vs VLF

PG `full_page_writes`: sau checkpoint, lần sửa page đầu ghi cả page vào WAL (FPI) — chống torn page. I/O WAL tăng sau checkpoint. SS: torn page detection / checksum; VLF số lượng quá nhiều hoặc quá lớn = recovery/truncate kỳ cục — `DBCC LOGINFO` (thận trọng prod).

### 8.2 Delayed durability vs synchronous_commit=off

Cả hai: `COMMIT` trả về trước flush bền. Crash mất txn đuôi. PG `WAIT FOR MODE primary_flush` (19) chờ flush trên primary — không bật sync cho mọi session. SS delayed durability database/table option — đọc Learn, không bịa tương tác AG.

### 8.3 Logical decode giữ xmin

Logical slot PG phải giữ tuple đủ decode → `xmin` horizon. 19 `retain_dead_tuples` + `max_retention_duration` — conflict resolution vs bloat. CES/CDC SS giữ **log**, không heap tuple theo xmin. Cùng “consumer chậm”, khác chỗ phình (WAL vs heap vs `.ldf`).

---

## 9. Buffer, checkpoint, dirty page

Writer đưa page bẩn xuống đĩa; checkpoint thu hẹp recovery window.

SQL Server: lazy writer, checkpoint, indirect checkpoint (recovery interval target). Buffer pool extension (SSD) tồn tại trên một số edition.

PostgreSQL: `shared_buffers`, `bgwriter`, `checkpointer`, `backend_flush_after`. Nhiều đọc **không** qua `shared_buffers` đủ lớn → OS cache. `checkpoint_timeout`, `max_wal_size`.

```text
Checkpoint quá thưa: crash recovery dài (WAL nhiều).
Checkpoint quá dày: I/O spike, full page writes (PG FPI).
Đo: pg_stat_bgwriter / pg_stat_checkpointer vs sys.dm_os_performance_counters.
```

**Ghi chú:** Giảm `shared_buffers` xuống 128 MB rồi so apples-to-apples với SS buffer pool 64 GB là vô nghĩa. Đo `pg_stat_bgwriter`, `pg_buffercache` (19: thêm hàm OS pages) vs `sys.dm_os_buffer_descriptors`.

**Kịch bản:** `max_wal_size` nhỏ + write nặng → checkpoint liên tục, disk 100%, OLTP latency. Tăng `max_wal_size` *và* đo recovery time — không phải “tắt checkpoint”.

---

## 10. Visibility: MVCC vs lock + version

### 10.0 Hình dung: photocopy trên bàn vs khóa cửa phòng

Cùng mục tiêu: người đọc không thấy bản *chưa lưu*, người ghi không làm hỏng người đọc. Hai cách:

```text
Cách A — khóa cửa (SQL Server mặc định, RCSI off)
  Muốn đọc phòng → cầm chìa S, đứng trong phòng.
  Muốn sửa → cần chìa X, đuổi người đang đọc.
  Sửa xong (in-place): phòng chỉ còn bản mới. Không có “phòng phụ”.

Cách B — photocopy (PostgreSQL; SQL Server RCSI gần ý này)
  Người đọc cầm tờ photocopy lúc họ bắt đầu câu/txn.
  Người ghi viết tờ mới (PG: thêm tuple trên heap) hoặc sửa phòng thật
  + cất tờ cũ vào kho version (SS RCSI: tempdb/PVS).
  Người đọc không vào phòng đang sửa → không đợi (SELECT thường).
```

Hệ quả trực tiếp: PG `SELECT` không block `UPDATE`. SS không RCSI thì có. PG bảng update nhiều **phình** (tờ cũ trên heap). SS RCSI **phình kho version**. Không có cách nào “không khóa, không photocopy, luôn đúng”.

Đây là chỗ **cùng mục tiêu, khác máy**.

**PostgreSQL:** mỗi `UPDATE`/`DELETE` tạo tuple mới. Snapshot (`xmin`/`xmax`) quyết định thấy bản nào. `SELECT` không S-lock. Writer-writer cùng tuple: row lock. Chi tiết [transactions.md](transactions.md) §8.

```text
PostgreSQL heap sau UPDATE (một hàng, hai phiên bản)

  t=0  [xmin=10 xmax=0 ]  live
  t=1  txn 20 UPDATE → [xmin=10 xmax=20] dead-when-20-commits
                       [xmin=20 xmax=0 ] live
  Snapshot xmin horizon = 15  → vẫn thấy bản 10 cho đến khi 15 xong
  VACUUM chỉ đụng bản xmax=20 khi horizon > 20
```

**SQL Server (RCSI off):** in-place (đại thể) + lock. Reader S, writer X. `READ COMMITTED` nhả S sớm.

**SQL Server RCSI/SI:** version store (tempdb hoặc ADR PVS) cho reader — gần *ý* MVCC nhưng version **tách** khỏi hàng hiện tại, không phải heap đầy tuple cũ như PG.

```text
SQL Server RCSI

  hàng hiện tại (in-place)  ← writer X
       │
       └── version chain trong tempdb/PVS  ← reader không S
```

Hệ quả thiết kế:

- PG: bảng “nóng update” **phình** (bloat) nếu vacuum chậm.
- SS không RCSI: reader block writer — báo cáo đè OLTP.
- SS RCSI: `tempdb`/ADR I/O; writer-writer vẫn khóa.
- Cùng `REPEATABLE READ` **không** cùng phantom/write-skew — đừng port isolation theo tên.

Optimized locking **2025** (TID + LAQ): giảm lock memory, không biến SS thành PG MVCC. [concurrency.md](concurrency.md) §4.

**Kịch bản write skew:** hai bác sĩ off-call — RR cả hai engine *có thể* để 0 người trực; PG SSI abort `40001`; SS serializable range *có thể* chặn. Không “bật RCSI là xong”. [transactions.md](transactions.md) §6.

### 10.1 Snapshot xmin vs version store size

```text
PG: SELECT backend_xmin FROM pg_stat_activity;
    xmin horizon = min(backend_xmin, slot xmin, prepared)
    VACUUM freeze vs wraparound — 19 cảnh báo sớm hơn (100 triệu xid)

SS: version store sys.dm_tran_version_store_space_usage
    RCSI + txn đọc lâu = PVS/tempdb phình
    ADR PVS trong user DB — không đổ hết tempdb
```

Long query báo cáo: PG giữ snapshot cả statement (RC) hoặc cả txn (RR). SS RCSI: statement version; SNAPSHOT: cả txn (3960 khi ghi đụng).

### 10.2 HOT vs in-place

PG HOT: update không đụng cột index, còn chỗ page → bản mới cùng page, index không sửa. Hết chỗ = heap tuple mới + dead. Fillfactor thấp tăng HOT, giảm mật độ đọc.

SS in-place: vừa chỗ thì sửa tại chỗ; không vừa → forwarded record (heap) hoặc page split (B-tree). Ghost record sau delete — cleanup task, không xmin wraparound.

---

## 11. Dọn rác: vacuum vs ghost / ADR

| Việc | SQL Server | PostgreSQL |
|---|---|---|
| Xóa logic | Ghost record + ghost cleanup task | Dead tuple + `VACUUM` |
| Thu hồi chỗ | Reuse sau cleanup; `REBUILD` gọn | VACUUM freeze + FSM; `REPACK` rewrite |
| Wraparound | — (log/LSN khác) | **XID wraparound** — vacuum bắt buộc |
| Online compact | `REORGANIZE` / `REBUILD ONLINE` | `REPACK (CONCURRENTLY)` **19** |

Autovacuum 19: **parallel** index, **scoring** (`pg_stat_autovacuum_scores`). Parallel AV lấy `SHARE UPDATE EXCLUSIVE` — không chặn DML thường, vẫn đợi/`ACCESS EXCLUSIVE` DDL, tranh I/O. [concurrency.md](concurrency.md) §13. SQL Server: ghost cleanup không có “score table” tương đương; stats update theo ngưỡng modification.

Long `idle in transaction` (PG) giữ `xmin` horizon → **cả cluster** không vacuum được một số tuple. SS: open tran giữ log reuse + (RCSI) version store.

`VACUUM FULL` / `REPACK` ≈ `ALTER TABLE REBUILD` về mặt “viết lại file”, không ≈ `REORGANIZE` (leaf defrag). [indexes.md](indexes.md) §10.

**Kịch bản bloat:** replica slot `xmin` đứng + `idle in transaction` 6 giờ → bảng 20 GB dead. `VACUUM` chạy, 0 pages cắt. Sửa horizon (kill idle, drop slot chết), không `REPACK` trước. Cảnh báo wraparound 19: 100 triệu xid (trước 40 triệu).

---

## 12. Temp: tempdb vs pgsql_tmp

**SQL Server `tempdb`:** database thật — table `#`, spilled sort/hash, version store (RCSI), snapshot. Cấu hình số file, ADR **2025**, **space resource governor** (lỗi **1138**). Tranh `tempdb` là incident cổ điển. RG Standard 2025. Linux: tmpfs.

**PostgreSQL:** sort/hash spill → file trong `base/pgsql_tmp` (hoặc tablespace temp). `CREATE TEMP TABLE` = heap trong schema `pg_temp_NN`, biến mất cuối session/txn (`ON COMMIT`). Không có “một tempdb” để gắn 8 file giống SS — nhưng disk đầy vì spill vẫn chết.

```text
SS:  mọi spill / #temp / version  →  một DB tempdb  →  dễ đo, dễ tranh
PG:  spill file per backend         + temp table catalog  →  phân tán
```

**Ghi chú:** “Chuyển tempdb sang SSD” không dịch thành một GUC. PG: `temp_tablespaces`, `work_mem` (spill ít hơn nếu RAM đủ — cẩn thận song song × `work_mem`).

**Kịch bản 1138:** group cap 1 GB, hash spill báo cáo → severity 17, không phải 1205. Retry cùng query fail. [concurrency.md](concurrency.md) §10.

---

## 13. Optimizer & statistics

Cùng pipeline: estimate cardinality → cost → chọn join/agg. Khác histogram, CE, hint.

**SQL Server:** CE theo compat (legacy vs 120+ vs 170). Parameter sniffing; PSPO / **OPPO 2025**; CE feedback **expression**; DOP feedback **ON mặc định**; Query Store (kể cả **readable secondary ON mặc định**). Hint `OPTION`, `ABORT_QUERY_EXECUTION`. **Persisted stats trên secondary** 2025 — I/O ghi replica.

**PostgreSQL:** cost `seq_page_cost` / `random_page_cost` / `cpu_*`. `ANALYZE` histogram + MCV. Extended stats (`CREATE STATISTICS`); 19 trên **virtual generated**, `pg_clear_extended_stats()`. `EXPLAIN (ANALYZE, BUFFERS, WAL, IO)`. 19: `NOT IN`→ANTI (không NULL), aggregate trước join, contrib `pg_plan_advice` / `pg_stash_advice`.

Thống kê cũ = plan sai **cả hai**. SS 2025: **persisted stats trên secondary**. PG: autovacuum analyze; 19 scoring.

Hint: SS phong phú (`LOOP JOIN`, `FORCESEEK`). PG: `pg_hint_plan` extension (không core) hoặc `pg_plan_advice` 19. `SET enable_hashjoin = off` chỉ debug. [indexes.md](indexes.md) §11.

**Kịch bản:** Compat 160→170 ngày cutover, DOP feedback đổi plan, không baseline Query Store → regression “không đụng code”. Giữ 160 đo rồi mới 170.

---

## 14. Parallelism

SQL Server: CXPACKET/CXCONSUMER, `MAXDOP`, cost threshold, IQP DOP feedback. Parallel SELECT/DML (tùy).

PostgreSQL: `max_parallel_workers_per_gather`, parallel seq/index/hash/aggregate. Parallel **autovacuum** 19. `VACUUM` index parallel từ trước. DML parallel hạn chế hơn SS ở một số path.

**Ghi chú:** `work_mem` × parallel workers = RAM nổ. SS memory grant quá lớn → `RESOURCE_SEMAPHORE`. Parallel AV vs lock: không như `VACUUM FULL`.

---

## 15. HA & replication

### 15.1 SQL Server

- **FCI:** shared storage, instance failover.
- **Always On AG:** replica, sync/async, readable secondary, distributed/contained AG. 2025: async page request recovery, commit wait ms, flow control, `REMOVE` listener IP, routing `NONE`, TLS 1.3/TDS 8.
- Log shipping, replication (transactional/merge/P2P) — breaking 2025 cùng TLS.
- **Fabric mirroring** (GA 2025) → OneLake; Synapse Link discontinued. RG theo phase; autoreseed khi log đầy.
- CES **PREVIEW:** DML → Event Hubs (CloudEvents). Giữ log như CDC.

```text
AG (rút gọn)

  Primary ════ sync ════ Secondary (commit đợi harden)
       └──── async ──── Secondary (stale read; không WAIT FOR LSN)
 Listener → routing READ_* ; 2025: NONE = về primary
```

### 15.2 PostgreSQL

- **Streaming physical:** WAL, hot standby, sync replica (`synchronous_standby_names`).
- **Logical:** publication/subscription. **19:** sequence sync (`ALL SEQUENCES`, `REFRESH SEQUENCES`), `wal_level=replica` bật logical không restart, `WAIT FOR LSN`, `CREATE SUBSCRIPTION … SERVER`.
- Ecosystem: Patroni, repmgr, CloudNativePG — **không** trong core như AG wizard.
- Slot giữ WAL + xmin. `retain_dead_tuples` + `max_retention_duration` 19.

```text
Physical streaming

  Primary WAL ──► walreceiver ──► startup/replay ──► hot standby
                                      │
                                      └── WAIT FOR LSN … MODE standby_replay
                                          (19, top-level, ≤ RC)

Logical

  Decoding → slot → subscriber apply
  Slot đứng = WAL + xmin horizon (bloat cluster)
```

### 15.3 Ánh xạ sai thường gặp

| Nghĩ | Thực tế |
|---|---|
| AG = streaming | Gần vai trò, khác quorum, listener, readable secondary stats |
| CDC = logical decoding | Gần; CES ≠ logical sub; slot ≠ capture instance |
| `WAITFOR DELAY` = `WAIT FOR` LSN | **Không** |
| Failover Group Azure = Patroni | Vận hành khác |
| Mirroring Fabric = AG DR | OneLake analytics; không thay RPO AG |

**Kịch bản RYW:** ghi primary, đọc standby async. PG 19: app chuyển LSN + `WAIT FOR` timeout, fail → đọc primary. SS: sync AG (đắt) hoặc không RYW; không lệnh LSN. [transactions.md](transactions.md) §11.

**Kịch bản failover:** SS listener + routing. PG: Patroni đổi VIP / DNS; slot logical failover 19 sequence `REFRESH SEQUENCES` — trước 19 `setval` tay. Physical standby promote: timeline mới; `WAIT FOR` số LSN cũ có thể lệch nghĩa.

### 15.4 Crash recovery — hai máy

```text
SQL Server
  1. Khởi động: đọc log từ last checkpoint (ADR: sLRU + PVS rút ngắn undo)
  2. Redo committed; undo uncommitted (ADR: không quét log cũ như trước)
  3. Tempdb ADR 2025: txn #temp rollback nhanh, log truncate
  4. AG: parallel redo; 2025 async page request khi recovery failover

PostgreSQL
  1. Startup process replay WAL từ redo pointer (control file)
  2. Không “undo log” kiểu SS: heap tuple xmax + clog quyết định abort
  3. Replica promote = replay xong + timeline mới
  4. Checksum online 19: CPU lúc bật/tắt, không phải recovery path riêng
```

**Kịch bản:** SS txn 50 GB rollback không ADR = recovery dài. PG: crash giữa `COPY` lớn — WAL replay, bảng có thể nửa dữ liệu committed statements (autocommit từng statement) hoặc cả txn tùy client.

### 15.5 Connection storm

```text
SS: 10k login đồng thời
  → THREADPOOL, hoặc PBKDF2 2025 hash login SQL chậm hơn MD5 cũ
  → pool + TDS 8 driver; không max worker = số connection

PG: 10k backend
  → RAM (work_mem × conn × parallel), file descriptor, proc array
  → PgBouncer; max_connections vài trăm; 19 lock default 128 × connections = lock table RAM
```

Không “tăng max_connections cho bằng SS”. SS connection rẻ hơn process PG; vẫn cần pool (implicit tran).

### 15.6 Redo vs “đọc replica”

Readable secondary SS: redo còn áp, query đọc version/snapshot replica — stats 2025 persist *ghi* trên secondary. PG hot standby: replay conflict giết query (`max_standby_streaming_delay`). `WAIT FOR` không giảm conflict; chỉ chờ LSN.

---

## 16. Backup & restore

SQL Server: FULL/DIFF/LOG; copy-only; **2025 full/diff trên secondary**; URL immutable blob; managed identity Arc; **ZSTD**. Recovery model SIMPLE không backup log.

PostgreSQL: `pg_basebackup`, `pg_dump`/`pg_dumpall`, WAL archive, `pg_verifybackup`. Incremental (18+ tooling). Point-in-time = base + WAL. Dump logic ≠ physical.

Nâng major PG: `pg_upgrade` hoặc dump. SS: setup.exe in-place + compat.

PG 19 incompatibility chặn upgrade: `btree_gist` inet/cidr ([indexes.md](indexes.md) §12), CR/LF trong tên, `MULE_INTERNAL`, dump `standard_conforming_strings=off`. SS 2025: gỡ DQS/MDS **trước**; Web edition discontinued.

**Kịch bản PITR PG:** base backup Chủ nhật + WAL archive. Restore: `recovery.signal` / `restore_command` đến timestamp. Slot logical **không** nằm trong base backup như AG replica — tạo lại sub. Dump `pg_dump` không thay PITR (không có WAL).

**Kịch bản SS log chain:** FULL → LOG → LOG. Gãy chain (SIMPLE giữa chừng, gỡ file) = mất PITR. Backup secondary 2025: copy trên replica, vẫn log chain theo recovery model. ZSTD: test restore, không chỉ backup job xanh.

**Kịch bản nâng 19:** `pg_upgrade --check` fail `btree_gist` inet — gỡ index, upgrade, tạo GiST mới. Dump 18 `standard_conforming_strings=off` không load. JIT off: báo cáo chậm hơn 18 nếu quên `jit=on`. Không compat level.

---

## 17. Extensibility

| | SQL Server | PostgreSQL |
|---|---|---|
| In-process code | CLR (hạn chế), T-SQL | PL/pgSQL, PL/Python, C extension |
| Index AM | Cố định + columnstore + vector **PREVIEW** | GiST/GIN/BRIN/hash + AM tùy biến (`IndexAmRoutines` **static 19**) |
| Foreign data | Linked server, PolyBase (2025 parquet không service) | FDW (`postgres_fdw`, `file_fdw`) |
| AI | `vector`, external model, REST proc | `pgvector`, app-side |
| Graph | SQL Graph cũ (NODE/EDGE) — không PGQ | **SQL/PGQ 19** `GRAPH_TABLE` (rewrite join) |

Extension C 19: hook `get_relation_info_hook` → `build_simple_rel_hook` — rebuild extension. SQL/PGQ = metadata + join, không engine graph riêng — [select.md](select.md).

---

## 18. Bảo mật engine

Cùng ý: login/role, GRANT, RLS (cả hai), encryption at rest (TDE vs filesystem/pgcrypto), audit.

Khác:

- SS: `DENY` > `GRANT`; ownership chaining; impersonation `EXECUTE AS`; Entra `WITH OBJECT_ID` 2025; PBKDF2 hash **mặc định** 2025; OAEP; Purview policies **discontinued** → role `##MS_*##`.
- PG: `pg_hba`; RLS policy; `SECURITY DEFINER` + **`search_path` cố định** (bẫy); 19: password expiration warning, `GRANT … GRANTED BY`, large object cho `pg_read_all_data`.

TDS 8 / TLS 1.3 vs libpq SSL + SNI 19: đều breaking client cũ nếu bắt TLS mới.

---

## 19. Edition, compat, GUC

**SQL Server:** SKU (Express 50 GB, Standard 32 core / 256 GB **2025**, EE). Feature `ONLINE` index historically EE. Resource Governor trên **Standard** 2025 (tempdb governor). Compat **160 vs 170** đổi optimizer, không đổi parser hết. `PREVIEW_FEATURES` database scoped (vector index, CES, fuzzy, …). Developer tách Standard vs Enterprise — staging khớp prod. Web **discontinued**.

**PostgreSQL:** không SKU. Mọi thứ core + extension. GUC `postgresql.conf` / `ALTER SYSTEM` / `SET`. Major version = feature gate. JIT **off mặc định 19**; `max_locks_per_transaction` default **128**.

Staging phải khớp: SS = đúng Developer SKU. PG = đúng major + extension + GUC.

---

## 20. Điểm 2025 / 19 trên kiến trúc

Không lặp changelog ngôn ngữ (nằm ở file chủ đề). Chỉ **hạ tầng**:

**SQL Server 2025**

- Optimized locking (TID/LAQ) — lock manager, cần ADR + RCSI cho đủ path.
- Tempdb ADR + space governor — isolation temp spill (1138).
- IQP/QS mặc định đổi (DOP, secondary QS) — plan + I/O replica; persisted stats secondary.
- TDS 8 / TLS 1.3 — protocol.
- ZSTD backup, backup secondary, Fabric mirroring, CES PREVIEW — log reuse.
- PBKDF2 — login store.
- Columnstore ordered NCCI / CS online — storage analytics, không MVCC.

**PostgreSQL 19**

- WAL/logical: sequence replication, `effective_wal_level`, `WAIT FOR LSN`.
- Vacuum: parallel, score, all-visible khi scan.
- I/O worker auto-scale; COPY SIMD; TOAST lz4; `COPY TO` JSON.
- Checksum online.
- `REPACK` rewrite heap (logical decode khi concurrent).
- Lock default 128; JIT off; `log_lock_waits` on; `pg_stat_lock`.
- FDW thừa isolation READ ONLY.
- `btree_gist` inet/cidr chặn `pg_upgrade`.

---

## 21. Chọn engine khi nào

Không phải “cái nào mạnh hơn”. Gợi ý kiến trúc:

- Đã nằm Windows/Azure SQL/AG/T-SQL lớn → SS 2025; vector/JSON on-prem còn preview — đo Azure vs on-prem.
- Extension, FDW, MVCC đọc nhiều, SQL/PGQ, kiểm soát GUC → PG 19 (GA khi ổn).
- Cùng app hai backend: viết ANSI + lớp dialect; **không** share isolation level theo tên; test bloat vs tempdb vs lock.

---

## 22. Best practices & checklist

- Giải thích sự cố bằng **đúng máy**: bloat ≠ fragmentation leaf; `tempdb` ≠ `work_mem`.
- Đo đúng view: `pg_stat_activity`/`pg_locks`/`pg_stat_lock` vs `dm_exec_requests`/`dm_tran_locks`.
- Replica: QS+stats secondary (SS) vs `WAIT FOR`/slot (PG) — hai runbook.
- Nâng major: SS compat từng bước; PG incompatibility list (strings, gist inet, JIT).
- Pool connection: PG gần như bắt buộc; SS vẫn cần (và implicit tran).
- Đừng tắt autovacuum / ghost cleanup “cho nhanh”.
- Log reuse: CES + mirroring + CDC cùng bảng — đo trước khi bật.
- Crash/recovery: hiểu checkpoint vs RPO, không chỉ backup “job xanh”.

---

## 23. Bẫy khi review

- Gọi heap PG là “thiếu clustered index” như thể bug.
- `NOLOCK` trên PG (không có).
- `BEGIN` T-SQL = mở txn.
- So `shared_buffers` với max server memory 1-1.
- AG sync = `synchronous_commit=off` “cho nhanh”.
- `VACUUM` mỗi đêm = `REORGANIZE`.
- Cross-db query port sang PG không FDW.
- CES + mirroring + CDC cùng bảng không đo log.
- `WAITFOR` vs `WAIT FOR`.
- Tưởng SQL Graph SS = SQL/PGQ.
- Compat 170 ngày cutover không baseline Query Store.
- `pg_upgrade` giữ `btree_gist` inet.
- RCSI = MVCC heap PG.
- Optimized locking = hết deadlock / write skew.
- JSON/vector on-prem = GA vì Azure GA.
- Parallel autovacuum = `ACCESS EXCLUSIVE`.

---

## 24. Version gates

| Chủ đề kiến trúc | SQL Server 2025 | PostgreSQL 19 |
|---|---|---|
| Protocol | TDS 8 / TLS 1.3 GA | SNI `pg_hosts.conf`; strings always on |
| Lock manager | Optimized locking GA (off on-prem) | `pg_stat_lock`; lock default 128 |
| Temp | ADR + governor GA (1138) | I/O workers scale; COPY SIMD |
| Visibility cleanup | Ghost + ADR | Parallel AV; all-visible on scan; `REPACK` |
| Replica extras | QS+stats secondary ON; Fabric mirror | Sequence logical; `WAIT FOR LSN` |
| Preview | Vector index, CES, fuzzy, nhiều JSON on-prem | Cả 19 **beta** đến GA |

Cú pháp: [select.md](select.md), [dml.md](dml.md), [ddl.md](ddl.md), [json.md](json.md), [typesystem.md](typesystem.md). Isolation: [transactions.md](transactions.md). Khóa: [concurrency.md](concurrency.md).

---

## Phụ lục A. Incident map — đúng máy

| Triệu chứng | SS nghĩ | PG nghĩ | Sai nếu |
|---|---|---|---|
| Bảng phình, I/O đọc tăng | Frag NCI / heap forward | Dead tuple / xmin horizon | `REORGANIZE` trên PG; `VACUUM FULL` mỗi đêm mù |
| Báo cáo block OLTP | Thiếu RCSI / NOLOCK | Không tồn tại (SELECT không S) | Port NOLOCK |
| Đầy log | CES/mirroring/CDC wait | Slot / archive_command fail | Shrink file mù |
| Replica stale | Async AG | Replay lag; quên WAIT FOR | `WAITFOR DELAY` |
| Temp đầy | tempdb 1138 / version store | pgsql_tmp + work_mem × DOP | “Một GUC tempdb” |
| Login chậm sau nâng | PBKDF2 / TDS 8 | scram + pool | Tăng max_connections |
| Plan đổi không đụng SQL | Compat 170 / DOP feedback | ANALYZE / generic plan / pg_plan_advice | Thêm index trùng |

---

## Phụ lục B. Sơ đồ recovery window

```text
Thời gian →
  checkpoint     checkpoint      crash
      │              │              │
 SS:  └─ redo ───────┴──────────────┤ undo uncommitted (ADR rút)
 PG:  └─ replay WAL ────────────────┤ clog + xmax; không undo log riêng

RPO: SS FULL = last log backup; SIMPLE = last checkpoint (mất sau đó)
     PG = last WAL archived + base backup
```

Đo recovery: SS `recovery interval` / indirect checkpoint. PG `checkpoint_timeout` + `max_wal_size` + FPI. Giảm window ≠ tắt durable.

---

## Phụ lục C. `ctid` / RID không ổn định

PG `ctid` đổi sau `VACUUM FULL`/`REPACK`/update không HOT. Không khóa FK bằng ctid. SS RID heap đổi sau rebuild/forward. Clustered key SS ổn định hơn RID — vẫn đổi nếu rebuild CX đổi khóa.

System column `xmin` không index UNIQUE nghiệp vụ. `COPY FROM WHERE xmin` **cấm** 19.

---

## Phụ lục D. Buffer pool vs OS cache — đo

```text
SS: sys.dm_os_buffer_descriptors — page trong buffer pool
    max server memory ≈ trần pool (+ clerk khác)
PG: pg_buffercache + pg_buffercache_os_pages() (19)
    shared_buffers nhỏ hơn RAM; hit OS cache không hiện “buffer hit” 100%
    EXPLAIN (ANALYZE, BUFFERS) shared vs read
So sánh hit ratio 99% SS với 70% shared_buffers PG: vô nghĩa nếu OS cache ấm
```

`effective_cache_size` không cấp phát. Giảm `shared_buffers` để “giống lab SS” phá production.

### Checkpoint spike

PG: sau checkpoint, FPI tăng WAL. `max_wal_size` nhỏ → checkpoint dày → I/O. SS: indirect checkpoint mượt recovery interval — log vẫn flush lúc commit (trừ delayed).

---

## Phụ lục E. Autovacuum parallel vs OLTP

```text
Worker AV index song song 19
  Lock: SUE — DML chạy; CIC / VALIDATE / VACUUM khác / REPACK copy đợi
  I/O: cap autovacuum_max_parallel_workers
  Horizon: idle-in-txn / slot — parallel không dọn
  Score: pg_stat_autovacuum_scores; GUC *_score_weight
Tắt AV “cho nhanh” → wraparound (cảnh báo 19: 100 triệu xid)
Ghost SS: không score table; REBUILD ≠ VACUUM
```

Scan 19 đánh dấu all-visible: index-only rẻ hơn, không thay freeze.

Version deltas (TDS 8, WAIT FOR, TID/LAQ, JSON on-prem PREVIEW, `json_array` `[]`) nằm **§20** và file chủ đề — không nhét what's-new vào sơ đồ process/WAL. Review kiến trúc: process, WAL, visibility, HA, temp — rồi mới cổng phiên bản.

Process: SS một `sqlservr`; PG postmaster + backend. WAL: `.ldf`/VLF vs `pg_wal`. Visibility: RCSI/PVS vs heap xmax. HA: AG listener vs streaming + slot + `WAIT FOR LSN`. Temp: tempdb 1138 vs `pgsql_tmp`. Pool bắt buộc phía PG; SS implicit tran vẫn cần `COMMIT`.

```text
Client ── protocol (TDS 8 / libpq) ── parser ── rewriter ── planner ── executor
                                              │
                                    buffer / WAL / heap
                                              │
                         replica: AG redo  |  PG replay + WAIT FOR (19)
```

Crash: SS redo + undo (ADR rút); PG replay WAL, visibility bằng clog/xmax. Đừng copy runbook recovery 1-1.

Connection storm: SS `THREADPOOL` / PBKDF2; PG `max_connections` + `work_mem` × backend. Replica: SS không `WAIT FOR LSN`; PG 19 `WAIT FOR LSN … MODE standby_replay` top-level, isolation ≤ RC. Slot/CES/mirroring: log reuse — [concurrency.md](concurrency.md).

---

## Phụ lục F. Checklist kiến trúc (WHY)

1. **Process: một `sqlservr` vs postmaster+backend** — crash/pool khác.
2. **`shared_buffers` ≠ max server memory** — PG còn OS cache.
3. **RCSI/PVS ≠ heap MVCC** — bloat vs version store.
4. **Log reuse: CES/mirroring/slot** — consumer chậm đầy đĩa.
5. **`WAIT FOR LSN` ≠ `WAITFOR DELAY`** — MODE `standby_replay` mới RYW.
6. **tempdb 1138 vs `work_mem` × DOP**.
7. **Nâng PG: gist inet, strings always on; SS: TDS 8, gỡ DQS**.
8. **Delta phiên bản ở §20** — file này là máy, không changelog.

