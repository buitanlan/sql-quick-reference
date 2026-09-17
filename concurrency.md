# Khóa & concurrency

> **Baseline:** SQL Server **2025** (17.x) · PostgreSQL **19**.  
> Bổ sung [transactions.md](transactions.md): đây là **lock, wait, deadlock, version store**. Isolation quyết định *thấy gì*; file này là *đợi gì, giết ai*.

SQL Server mặc định **pessimistic** (lock manager) + tùy chọn row versioning (RCSI/SI). PostgreSQL **MVCC**: reader không block writer; writer block writer trên **cùng tuple**. Cùng `FOR UPDATE` / `UPDLOCK` không cùng hàng đợi. Optimized locking **2025** giảm lock memory — **không** đổi isolation. Deadlock `1205` vs `40001`/`40P01`. `SKIP LOCKED` ≠ `READPAST` hết nuance. Slot CES / logical replication / Fabric mirroring giữ xmin/log.

DDL lock, `REPACK`: [ddl.md](ddl.md), [indexes.md](indexes.md). Retry: [transactions.md](transactions.md) §13. Kiến trúc lock vs MVCC: [internal.md](internal.md).

---

## Mục lục

- [1. Tổng quan \& triết lý](#1-tổng-quan--triết-lý)
  - [1.1 Hình dung: khóa là biển “đừng đụng”](#11-hình-dung-khóa-là-biển-đừng-đụng-không-phải-isolation)
- [2. SQL Server: granularity \& mode](#2-sql-server-granularity--mode)
- [3. Escalation](#3-escalation)
- [4. Optimized locking (2025)](#4-optimized-locking-2025)
- [5. PostgreSQL: lock bảng](#5-postgresql-lock-bảng)
- [6. FOR UPDATE và biến thể](#6-for-update-và-biến-thể)
- [7. SKIP LOCKED vs READPAST](#7-skip-locked-vs-readpast)
- [8. Deadlock 1205 / 40P01 / 40001](#8-deadlock-1205--40p01--40001)
- [9. Hint \& timeout](#9-hint--timeout)
- [10. tempdb governor, ADR, bloat / xmin](#10-tempdb-governor-adr-bloat--xmin)
- [11. CES, mirroring, replication slot](#11-ces-mirroring-replication-slot)
- [12. pg\_stat\_lock \& log\_lock\_waits](#12-pg_stat_lock--log_lock_waits)
- [13. Parallel autovacuum vs lock](#13-parallel-autovacuum-vs-lock)
  - [13.1 Tương thích lock bảng](#131-tương-thích-lock-bảng-postgresql)
  - [13.2 Latch ≠ lock](#132-latch--lock-sql-server)
  - [13.3 Hotspot một hàng / một page](#133-hotspot-một-hàng--một-page)
- [14. Worked examples](#14-worked-examples)
- [15. Best practices \& checklist](#15-best-practices--checklist)
- [16. Bẫy khi review](#16-bẫy-khi-review)
- [17. Version gates](#17-version-gates)
- [Phụ lục A. pg\_stat\_lock](#phụ-lục-a-pg_stat_lock--đọc-số)
- [Phụ lục B. Optimized locking — bật/tắt](#phụ-lục-b-optimized-locking--thứ-tự-bậttắt)
- [Phụ lục C. Hai session — thứ tự khóa](#phụ-lục-c-hai-session--thứ-tự-khóa-mẫu)

---

## 1. Tổng quan & triết lý

Đồng thời = hoặc **khóa** (chờ) hoặc **phiên bản** (snapshot) hoặc **abort** (SSI / deadlock victim). Không có “không khóa, không version, luôn đúng”.

- **SQL Server (RCSI off):** reader S, writer X — hai chiều block trên cùng resource.
- **SQL Server RCSI:** reader version, không S; writer-writer vẫn X (hoặc TID lock khi optimized locking).
- **PostgreSQL:** `SELECT` thường không row-lock; `UPDATE` khóa tuple; snapshot theo isolation — [transactions.md](transactions.md) §8.

Transaction **ngắn**. Giữ khóa qua HTTP/UI = queue dài (SS) hoặc `idle in transaction` + xmin (PG). Optimized locking / MVCC không cứu txn mở 20 phút.

PostgreSQL 19: `log_lock_waits` **bật mặc định**; `pg_stat_lock`. SQL Server 2025: optimized locking **tắt mặc định** trên on-prem (bật per database); Azure SQL luôn on.

### 1.1 Hình dung: khóa là biển “đừng đụng”, không phải isolation

Isolation (§ trên [transactions.md](transactions.md)) = *tôi thấy gì*. Khóa = *ai phải đứng chờ, hoặc ai bị giết khi vòng chờ*.

Hình dung hành lang khách sạn:

```text
Hàng (KEY/RID / tuple)  = một phòng
Page                     = một tầng (nhiều phòng)
Bảng (OBJECT)            = cả tòa
Intent IS/IX             = biển ở sảnh: “có người đang làm việc trên một tầng”
                          không khóa từng phòng, nhưng chặn ai muốn khóa cả tòa
```

Muốn sửa phòng 1204, SQL Server không chỉ treo X trên 1204: còn treo **IX trên bảng** (“có người ghi trong tòa này”). Vì thế `ALTER TABLE` (Sch-M / `ACCESS EXCLUSIVE`) phải đợi hết khách — không phải vì DDL “nặng”, mà vì biển sảnh không tương thích.

PostgreSQL `SELECT` **không** treo biển trên phòng. `UPDATE` treo tuple. `DROP TABLE` / `VACUUM FULL` treo `ACCESS EXCLUSIVE` = đuổi cả tòa, kể cả người chỉ đi qua (`SELECT`).

Deadlock = hai người, mỗi người đã vào một phòng, muốn phòng của nhau, không ai chịu ra. Engine **giết một người** (SS `1205`, PG `40P01`) — không phải “chờ thêm”. SSI `40001` là chuyện **khác**: không vòng khóa, mà “hai bản chụp không xếp thành một lịch sử”. Đừng retry `40001` như timeout mạng rồi hy vọng hết write skew mà không đổi isolation/schema.

Escalation (SS) = quá nhiều biển phòng → đổi thành một biển cả tòa. Một X bảng: mọi người khác dừng. TID locking 2025 (§4) = thay nghìn biển phòng bằng một biển “giao dịch số 88 đang sửa” — ít escalate, **không** đổi chuyện bạn thấy gì.

```text
Đợi gì?
  SS pessimistic: S ↔ X trên KEY/PAGE/OBJECT
  SS RCSI:        reader không đợi writer; writer đợi writer
  SS optimized:   X hàng ngắn + X trên TID; LAQ khóa sau khi khớp predicate
  PG:             tuple lock (FOR UPDATE / UPDATE); bảng ACCESS EXCLUSIVE chặn SELECT
```

---

## 2. SQL Server: granularity & mode

Granularity: RID / KEY / PAGE / OBJECT (bảng) / DATABASE / METADATA. Intent (IS/IX/SIX) trên cấp cao hơn trước khi khóa hàng/page.

**Vì sao intent tồn tại.** Nếu chỉ khóa hàng, `DROP TABLE` phải quét *mọi* hàng xem có S/X không — không làm được. Biển IX trên bảng = “có ghi bên trong”: `Sch-M` thấy IX là biết phải đợi, không cần liệt kê từng KEY.

```text
Session A: UPDATE … WHERE id=5
  1. Xin IX trên bảng Orders     (biển sảnh: có người ghi)
  2. Xin IX trên page chứa id=5
  3. Xin X trên KEY id=5

Session B: SELECT * FROM Orders (RC, chưa RCSI)
  1. Xin IS trên bảng            — IS + IX = tương thích (cùng tòa, khác việc)
  2. Xin S trên từng KEY đọc     — gặp KEY id=5 đang X → ĐỢI

Session C: ALTER TABLE Orders ADD …
  1. Xin Sch-M trên bảng         — Sch-M không đi với IX → ĐỢI A xong
```

RCSI: Session B **bỏ bước S trên KEY**, đọc version — không đợi A. Session C vẫn đợi IX. RCSI không làm DDL “nhẹ hơn”.

| Mode | Ý nghĩa |
|---|---|
| S | Shared — đọc (pessimistic RC) |
| U | Update — tránh convert deadlock reader→writer |
| X | Exclusive — ghi |
| IS / IX / SIX | Intent trên bảng/page |
| Sch-S / Sch-M | Schema — DML vs DDL |
| Range* | Serializable key-range |

```sql
SELECT * FROM sys.dm_tran_locks;
SELECT * FROM sys.dm_os_waiting_tasks;
SELECT session_id, blocking_session_id, wait_type, wait_resource
FROM sys.dm_exec_requests
WHERE blocking_session_id <> 0;
```

`UPDLOCK` lấy U khi `SELECT` để RMW. `ROWLOCK` xin hàng, không bảo đảm không escalate. `HOLDLOCK` = serializable hint trên câu.

Wait type cổ điển: `LCK_M_S`, `LCK_M_X`, `LCK_M_U`, `LCK_M_SCH_M`. Optimized locking thêm kịch bản wait trên **TID** (resource khác KEY) — đọc `wait_resource` / deadlock XML sau khi bật, đừng giả định graph 2019.

**Ghi chú:** `NOLOCK` / `READ UNCOMMITTED` = dirty, đọc hai lần một hàng, bỏ hàng đang move page. Không dùng tiền/tồn kho. Ưu tiên RCSI — [transactions.md](transactions.md) §7.

---

## 3. Escalation

Nhiều lock hàng/page → engine **escalate** lên bảng (hoặc partition). Ngưỡng cổ điển ~5000 locks mỗi statement (không phải con số SLA). Escalation: một X bảng, chặn mọi người — throughput rơi.

```sql
-- Dấu hiệu
-- wait KEY/PAGE rồi bỗng OBJECT; deadlock graph table lock
SELECT * FROM sys.dm_db_index_operational_stats(DB_ID(), OBJECT_ID(N'dbo.Orders'), NULL, NULL);
```

Giảm escalation: batch nhỏ, index seek (đừng scan + X hàng loạt), `ROWLOCK` không đủ. **2025 optimized locking** (mục 4) giảm số lock giữ đến cuối txn → escalation **ít xảy ra hơn**. Không tắt escalation bằng magic hint ổn định (có `LOCK_ESCALATION` trên bảng — dùng có chủ đích).

```sql
ALTER TABLE dbo.Orders SET (LOCK_ESCALATION = AUTO);   -- partition
-- DISABLE: hiếm khi đúng trên OLTP rộng
```

**Ghi chú:** `TABLOCKX` cố ý escalate. Bulk staging OK; OLTP không.

---

## 4. Optimized locking (2025)

Hai thành phần (Learn):

1. **TID locking:** mỗi txn một Transaction ID. Hàng bị sửa gắn TID. Thay vì giữ hàng nghìn X key đến `COMMIT`, giữ **một X trên TID**; lock hàng/page **nhả ngay sau khi sửa từng hàng**.
2. **LAQ (Lock After Qualification):** đánh giá predicate trên bản **committed mới nhất** **không** lấy lock; chỉ lấy X khi hàng *khớp* để sửa. **Cần RCSI**. Không áp `REPEATABLE READ` / `SERIALIZABLE` (vẫn cần giữ lock chống phantom).

```text
UPDATE 1000 hàng, RC, một txn

Không optimized:
  X(key1) ────────────────────────────── COMMIT
  X(key2) ────────────────────────────── COMMIT
  … 1000 X giữ hết txn → dễ escalate

Optimized (TID):
  X(key1) ─ sửa ─ nhả
  X(key2) ─ sửa ─ nhả
  X(TID)  ────────────────────────────── COMMIT
  Ai đọc hàng “đang sửa bởi TID”? đợi TID (hoặc version nếu RCSI)
```

```sql
-- Điều kiện: ADR trước; RCSI để có LAQ
ALTER DATABASE Sales SET ACCELERATED_DATABASE_RECOVERY = ON;
ALTER DATABASE Sales SET READ_COMMITTED_SNAPSHOT ON;
ALTER DATABASE Sales SET OPTIMIZED_LOCKING = ON;

SELECT DATABASEPROPERTYEX(DB_NAME(), 'IsOptimizedLockingOn');
SELECT name, is_accelerated_database_recovery_on,
       is_read_committed_snapshot_on, is_optimized_locking_on
FROM sys.databases
WHERE name = DB_NAME();
```

On-prem 2025: **không** bật mặc định. Azure SQL / Fabric SQL DB: luôn on. Tắt ADR phải tắt optimized locking trước.

Không thay thế:

- `UPDLOCK` khi đọc-rồi-ghi (lost update).
- Serializable / constraint khi write skew.
- Retry deadlock.
- Isolation level.

LAQ: `UPDATE … WHERE status = 'open'` không X hàng `status='paid'` chỉ vì chúng nằm cùng page scan — khóa **sau** khi thấy hàng khớp. Predicate không sargable vẫn có thể đọc nhiều hàng; LAQ không biến scan thành seek.

**Ghi chú:** Schema lock không đổi. `SELECT` vẫn theo isolation. Test deadlock graph sau khi bật — một số deadlock *giảm* (convert U→X, lock lifetime ngắn), không phải hết vòng A/B. Compat: engine 2025; không bịa GUC. Isolation / ADR: [transactions.md](transactions.md) §7.

---

## 5. PostgreSQL: lock bảng

Cấp bảng (`pg_locks.mode`), nặng dần:

| Mode | Ví dụ |
|---|---|
| `ACCESS SHARE` | `SELECT` |
| `ROW SHARE` | `SELECT FOR UPDATE` / `FOR SHARE` |
| `ROW EXCLUSIVE` | `INSERT`/`UPDATE`/`DELETE` |
| `SHARE UPDATE EXCLUSIVE` | `VACUUM`, `ANALYZE`, `CREATE INDEX CONCURRENTLY`, `VALIDATE CONSTRAINT`, `REPACK (CONCURRENTLY)` lúc copy |
| `SHARE` | `CREATE INDEX` (không concurrent) |
| `SHARE ROW EXCLUSIVE` | một số `CREATE TRIGGER` / `ALTER` |
| `EXCLUSIVE` | `REFRESH MATERIALIZED VIEW CONCURRENTLY` (một pha) |
| `ACCESS EXCLUSIVE` | `DROP`, `ALTER TABLE` rewrite, `VACUUM FULL`, `REPACK` không concurrent, swap `REPACK (CONCURRENTLY)`, `LOCK TABLE` |

Hai mode **không tương thích** → wait. `ACCESS EXCLUSIVE` chặn cả `SELECT`.

```sql
SELECT * FROM pg_locks WHERE NOT granted;
SELECT pid, state, wait_event_type, wait_event, query
FROM pg_stat_activity
WHERE wait_event_type = 'Lock';

SELECT * FROM pg_stat_lock;          -- PG 19: thống kê theo loại lock
```

`log_lock_waits` **mặc định on** từ **19**. `deadlock_timeout` mặc định 1s rồi deadlock check. `max_locks_per_transaction` default **128** (19; trước 64) — nhân đôi setting cũ nếu muốn cùng capacity; lock memory tăng.

`REPACK (CONCURRENTLY)`: `SHARE UPDATE EXCLUSIVE` lúc copy + logical decoding stash; `ACCESS EXCLUSIVE` **lúc swap**. Deadlock lock-upgrade lúc swap là hazard **beta** — [indexes.md](indexes.md) §10. `lock_timeout` abort statement, không chờ vô hạn.

---

## 6. FOR UPDATE và biến thể

PostgreSQL row lock (yếu → mạnh):

| Mệnh đề | Chặn |
|---|---|
| `FOR KEY SHARE` | Không cho xóa / sửa khóa unique |
| `FOR SHARE` | Không cho UPDATE/DELETE |
| `FOR NO KEY UPDATE` | Như UPDATE không đụng unique key |
| `FOR UPDATE` | Như UPDATE/DELETE |

```sql
SELECT * FROM accounts WHERE id = 1 FOR UPDATE;
SELECT * FROM accounts WHERE id = 1 FOR UPDATE NOWAIT;
SELECT * FROM accounts WHERE id = 1 FOR NO KEY UPDATE;
SELECT * FROM orders o JOIN customers c ON c.id = o.customer_id
    FOR UPDATE OF o;                 -- chỉ khóa alias o
```

`OF alias` bắt buộc khi join — thiếu = khóa **mọi** bảng trong FROM (bất ngờ).

SQL Server không `FOR UPDATE` trên `SELECT` ngoài cursor. Dùng hint:

```sql
SELECT qty
FROM dbo.Stock WITH (UPDLOCK, ROWLOCK, HOLDLOCK)
WHERE Sku = N'A';
```

`HOLDLOCK` giữ đến cuối txn (serializable phạm vi). `UPDLOCK` không `HOLDLOCK` = U lock theo isolation (RC nhả sớm hơn RR). Optimized locking: `UPDLOCK` vẫn cần cho RMW — TID không thay U lock lúc đọc.

**Ghi chú:** PG `SELECT FOR UPDATE` ở RC: sau khi đợi, statement **re-check** hàng — hàng có thể biến mất. RR/SSI: conflict `40001`. Temporal `FOR PORTION OF`: khóa trước — [dml.md](dml.md), [constraints.md](constraints.md).

---

## 7. SKIP LOCKED vs READPAST

Queue worker song song: lấy hàng **không** đang bị khóa, không chờ.

```sql
-- PostgreSQL
SELECT id FROM job_queue
WHERE status = 'ready'
ORDER BY id
FOR UPDATE SKIP LOCKED
LIMIT 10;

-- SQL Server
SELECT TOP (10) Id
FROM dbo.JobQueue WITH (READPAST, UPDLOCK, ROWLOCK)
WHERE Status = N'ready'
ORDER BY Id;
```

| | `SKIP LOCKED` (PG) | `READPAST` (SS) |
|---|---|---|
| Bỏ hàng đang lock | Có | Có (không đợi) |
| Fairness | Không | Không |
| Kết hợp | `FOR UPDATE`/`SHARE` | Thường `UPDLOCK, ROWLOCK` |
| Dirty | Không | `READPAST` ≠ `NOLOCK` |

Không fairness: worker có thể đói. Không dùng cho “đúng thứ tự tuyệt đối” trừ một worker. `NOWAIT` = lỗi ngay nếu đụng lock, không skip.

**Ghi chú:** `READPAST` trên isolation serializable / hint range: đọc docs — skip page lock khác skip row. Test. Thiếu `UPDLOCK` + `READPAST` = đọc skip nhưng không giữ hàng → hai worker lấy cùng job.

---

## 8. Deadlock 1205 / 40P01 / 40001

Hai session, thứ tự khóa **ngược**. Engine chọn victim. Đây là chuyện **lock wait cycle** — khác SSI `40001` (không nhất thiết có cycle).

**Hình dung hai loại “40001 / 1205” hay bị trộn:**

```text
Deadlock (SS 1205, PG 40P01)
  Hai người, mỗi người đã khóa một phòng, muốn phòng kia.
  Có chu trình chờ. Engine giết một người để đứt chu trình.
  Chữa: khóa theo thứ tự cố định (id tăng), txn ngắn.

SSI / serialization (PG 40001, SS SNAPSHOT 3960)
  Không cần chu trình khóa. Hai bản chụp “đều hợp lệ riêng”
  nhưng xếp chung một lịch sử thì vỡ invariant (write skew).
  Chữa: SERIALIZABLE + retry, hoặc một chỗ ghi (counter), không phải “thêm hint NOLOCK”.
```

Cùng mã `40001` trên PostgreSQL vừa deadlock vừa SSI — đọc **message** (`deadlock detected` vs `could not serialize access`). Retry giống nhau (cả txn); *nguyên nhân* khác.

### 8.1 Kịch bản hai session (chuyển khoản)

Bảng `accounts(id, balance)`. Invariant: trừ A, cộng B trong **một** txn. Hai session chuyển ngược chiều.

```text
Thời điểm →

S1: BEGIN
S1: UPDATE accounts SET balance = balance - 10 WHERE id = 1;   -- khóa hàng 1
        S2: BEGIN
        S2: UPDATE accounts SET balance = balance - 5 WHERE id = 2;  -- khóa hàng 2
S1: UPDATE accounts SET balance = balance + 10 WHERE id = 2;   -- đợi S2 (hàng 2)
        S2: UPDATE accounts SET balance = balance + 5 WHERE id = 1;  -- đợi S1 (hàng 1)
        ── cycle ── engine giết một session
```

### 8.2 SQL Server — chạy thật

```sql
-- Cả hai: SET XACT_ABORT ON;  (khuyến nghị)
-- Session 1
BEGIN TRAN;
UPDATE dbo.Accounts SET Balance = Balance - 10 WHERE Id = 1;
-- dừng, chạy session 2 hết câu UPDATE đầu

UPDATE dbo.Accounts SET Balance = Balance + 10 WHERE Id = 2;
-- đợi

-- Session 2
BEGIN TRAN;
UPDATE dbo.Accounts SET Balance = Balance - 5 WHERE Id = 2;

UPDATE dbo.Accounts SET Balance = Balance + 5 WHERE Id = 1;
-- một trong hai: Msg 1205, deadlock victim; txn victim đã rollback
```

Error **1205**, severity 13. Victim **đã** rollback — `CATCH` rồi `COMMIT` là sai. Retry cả txn — [transactions.md](transactions.md) §13.

Chẩn đoán:

```sql
-- Extended Events: xml_deadlock_report (thay trace flag 1222 trên prod hiện đại)
-- SQL Server Management Studio: deadlock graph
-- resource: KEY vs OBJECT (escalation) vs TID (optimized locking)
```

Optimized locking: lock hàng nhả sớm → *một lớp* deadlock convert U/X có thể giảm. Vòng “S1 giữ 1 cần 2, S2 giữ 2 cần 1” **vẫn xảy ra** vì hai X (hoặc TID) còn sống đến `COMMIT` của từng hàng chưa xong đối tác. Test 1205 trước/sau khi bật — đừng hứa “hết deadlock”.

### 8.3 PostgreSQL — cùng chuyện

```sql
-- Session 1
BEGIN;
UPDATE accounts SET balance = balance - 10 WHERE id = 1;
-- dừng

UPDATE accounts SET balance = balance + 10 WHERE id = 2;

-- Session 2
BEGIN;
UPDATE accounts SET balance = balance - 5 WHERE id = 2;

UPDATE accounts SET balance = balance + 5 WHERE id = 1;
```

```
ERROR:  deadlock detected
DETAIL:  Process 123 waits for ShareLock on transaction 999; blocked by process 456.
        Process 456 waits for ShareLock on transaction 888; blocked by process 123.
SQLSTATE: 40P01
```

Txn aborted (như mọi lỗi PG). `ROLLBACK` rồi retry. `deadlock_timeout` (mặc định 1s) = thời gian chờ trước khi *kiểm* cycle — không phải timeout abort. `log_lock_waits` (19: **on**) log wait dài hơn `deadlock_timeout` *không* phải deadlock.

### 8.4 `40001` không phải deadlock khóa

```
ERROR:  could not serialize access due to concurrent update
SQLSTATE: 40001
```

RR/SSI: snapshot đụng ghi. Không có cycle lock trong `pg_locks`. Retry giống 1205 về *app*, khác runbook (không đọc deadlock XML). Write skew SSI cũng `40001` — [transactions.md](transactions.md) §6.

### 8.5 Tránh

**Một thứ tự khóa toàn cục** (luôn `UPDATE` id nhỏ trước), txn ngắn, không hotspot một hàng counter, atomic `UPDATE … WHERE id = ?`. Hai chiều chuyển khoản: `WHERE id IN (1,2)` một câu không đủ nếu engine không khóa cùng thứ tự — `SELECT … FOR UPDATE` / `UPDLOCK` **ORDER BY id** trước rồi mới sửa.

---

## 9. Hint & timeout

```sql
-- SQL Server
SELECT … FROM dbo.T WITH (NOLOCK);              -- dirty; tránh
SELECT … FROM dbo.T WITH (UPDLOCK, ROWLOCK);
SELECT … FROM dbo.T WITH (TABLOCKX);
SELECT … FROM dbo.T WITH (READPAST, UPDLOCK, ROWLOCK);

SET LOCK_TIMEOUT 1000;                          -- ms; -1 = wait forever
SELECT … OPTION (LOCK_TIMEOUT 1000);            -- hint query (phiên bản hỗ trợ)

-- PostgreSQL: không hint NOLOCK / UPDLOCK
SET lock_timeout = '1s';
SET deadlock_timeout = '1s';
SET idle_in_transaction_session_timeout = '30s';
```

PostgreSQL: isolation + `FOR UPDATE` + GUC timeout. `SET enable_seqscan = off` là dao debug, không concurrency. `pg_plan_advice` 19 ghim plan — [indexes.md](indexes.md); không phải lock hint.

SQL Server `QUERYTRACEON` / `ABORT_QUERY_EXECUTION` (2025 Query Store hint) chặn query độc — không phải lock hint.

**Ghi chú:** `LOCK_TIMEOUT 0` = NOWAIT. App phải xử lý error **1222**, không nuốt thành 0 hàng. Hint trong view = mọi caller chịu.

---

## 10. tempdb governor, ADR, bloat / xmin

### 10.1 Tempdb space governor (SQL Server 2025)

Resource Governor workload group:

- `GROUP_MAX_TEMPDB_DATA_MB`
- `GROUP_MAX_TEMPDB_DATA_PERCENT`

Vượt → abort query **error 1138** (severity 17). RG có trên **Standard** 2025 (không chỉ EE). Đo `sys.dm_resource_governor_workload_groups`.

```text
Báo cáo hash spill / sort lớn
  → tempdb pages tăng
  → chạm cap group
  → 1138, statement chết
App không bắt 1138 → user “timeout”; không phải deadlock 1205
```

Governor **không** giới hạn data user DB. Cap quá chặt = báo cáo đêm fail; quá lỏng = một tenant phá tempdb. Linux 2025: `tempdb` trên **tmpfs** — đầy RAM/tmpfs vẫn 1138/disk.

### 10.2 ADR trong tempdb (2025)

Recovery txn temp (temp table) nhanh, log truncate mạnh — giảm đầy log tempdb khi `#temp` lớn rollback. Version store RCSI/SI: `tempdb` hoặc PVS (ADR user DB) — reader không S nhưng I/O version tăng. ADR user DB + RCSI = nền optimized locking — §4, [transactions.md](transactions.md) §7.

### 10.3 PostgreSQL bloat / xmin

`UPDATE`/`DELETE` để dead tuple. `VACUUM` thu hồi khi không snapshot nào còn thấy (`xmin` horizon).

Giữ horizon: `idle in transaction`, prepared xact, **replication slot**, `retain_dead_tuples` trên publication **19**.

**19:** scan query đánh dấu page **all-visible**; autovacuum **parallel** index (`autovacuum_max_parallel_workers`); scoring `pg_stat_autovacuum_scores`. Bloat nặng: `REPACK (CONCURRENTLY)` — không `ACCESS EXCLUSIVE` suốt copy.

```sql
SELECT pid, state, xact_start, wait_event
FROM pg_stat_activity
WHERE state = 'idle in transaction';

SELECT slot_name, slot_type, xmin, restart_lsn
FROM pg_replication_slots;
```

Cảnh báo wraparound xid **19** sớm hơn (100 triệu vs 40 triệu trước). `idle_in_transaction_session_timeout` bắt session quên `COMMIT`.

---

## 11. CES, mirroring, replication slot

Cùng họ: **consumer chậm → log/WAL không truncate → đầy đĩa**.

### 11.1 Change Event Streaming (SQL Server 2025, PREVIEW)

DML → Event Hubs / Fabric Eventstream (CloudEvents JSON/Avro). Cần `PREVIEW_FEATURES`. Giữ log như CDC. Không thay isolation; không `WAIT FOR` LSN kiểu PG.

CU có thể đổi API. Entra từ CU3 (Arc/Azure VM) theo Learn — đối chiếu, không khóa version số trong app.

### 11.2 Fabric mirroring (GA 2025)

SQL Server → OneLake. Synapse Link **discontinued**. Resource governor **theo phase** mirroring (không một cap cho cả pipeline). **Autoreseed** khi mirroring kẹt chống đầy log — hiểu cửa sổ continuity theo docs, không giả CDC exactly-once.

`log_reuse_wait_desc` có thể là replication / mirroring / CDC / CES — soi `sys.databases`. CES **PREVIEW** và mirroring **GA** là hai đường: bật cả hai trên cùng bảng mà không đo log = incident.

### 11.3 PostgreSQL slot

Slot không advance → WAL giữ + `xmin` horizon → bloat **toàn cluster**. **19:** publish **sequence** (`ALL SEQUENCES`, `REFRESH SEQUENCES`); `retain_dead_tuples` + `max_retention_duration`; `mem_exceeded_count` trên `pg_stat_replication_slots`; `wal_level=replica` có thể bật logical không restart (`effective_wal_level`).

```sql
SELECT slot_name, active, restart_lsn, xmin, mem_exceeded_count
FROM pg_stat_replication_slots;   -- cột 19: đối chiếu catalog nếu CU/beta đổi tên
```

Drop slot chết. `retain_dead_tuples` không `max_retention_duration` = bloat vô hạn.

**Ghi chú:** AG readable secondary SS không có `WAIT FOR replay`; PG 19 standby: [transactions.md](transactions.md) §11.

### 11.4 Chẩn đoán chuỗi block

```sql
-- SQL Server: ai chặn ai (rút gọn)
SELECT r.session_id, r.blocking_session_id, r.wait_type, r.wait_time,
       t.text
FROM sys.dm_exec_requests AS r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE r.blocking_session_id <> 0 OR r.session_id IN (
    SELECT blocking_session_id FROM sys.dm_exec_requests
    WHERE blocking_session_id <> 0
);

-- PostgreSQL
SELECT blocked.pid AS blocked_pid,
       blocking.pid AS blocking_pid,
       blocked.query AS blocked_query,
       blocking.query AS blocking_query
FROM pg_stat_activity AS blocked
JOIN pg_locks AS bl ON bl.pid = blocked.pid AND NOT bl.granted
JOIN pg_locks AS gl ON gl.locktype = bl.locktype
    AND gl.database IS NOT DISTINCT FROM bl.database
    AND gl.relation IS NOT DISTINCT FROM bl.relation
    AND gl.page IS NOT DISTINCT FROM bl.page
    AND gl.tuple IS NOT DISTINCT FROM bl.tuple
    AND gl.virtualxid IS NOT DISTINCT FROM bl.virtualxid
    AND gl.transactionid IS NOT DISTINCT FROM bl.transactionid
    AND gl.classid IS NOT DISTINCT FROM bl.classid
    AND gl.objid IS NOT DISTINCT FROM bl.objid
    AND gl.objsubid IS NOT DISTINCT FROM bl.objsubid
    AND gl.granted
JOIN pg_stat_activity AS blocking ON blocking.pid = gl.pid
WHERE blocked.pid <> blocking.pid;
```

Head blocker thường là `idle in transaction` (PG) hoặc session SS quên `COMMIT` / implicit transaction. Kill có chủ đích; sửa pool trước.

**Ghi chú:** Join `pg_locks` như trên là mẫu cổ điển — vẫn đúng 19; thêm `pg_stat_lock` (§12) để xem *loại* lock hot, không thay pid đang đợi.

---

## 12. pg_stat_lock & log_lock_waits

### 12.1 `pg_stat_lock` (PostgreSQL 19)

View **tích lũy**, một hàng mỗi `locktype` (loại đối tượng khóa — `relation`, `transactionid`, `tuple`, `page`, `advisory`, … — **không** phải mode `ACCESS EXCLUSIVE`). `pg_locks` = snapshot hiện tại; `pg_stat_lock` = lịch sử contention.

Cột (docs 19 / catalog): `locktype`, `waits`, `wait_time` (ms), `fastpath_exceeded`, `stats_reset`. `waits` / `wait_time` tăng khi lock **xin được sau khi đợi** lâu hơn `deadlock_timeout` — không đếm mọi wait ngắn.

`fastpath_exceeded`: hết fast-path slot → lock nặng hơn. Tăng `max_locks_per_transaction` (19 default **128**) có thể giảm.

```sql
SELECT locktype, waits, wait_time, fastpath_exceeded
FROM pg_stat_lock
ORDER BY wait_time DESC;
```

Không thay `pg_stat_activity` lúc incident. Dashboard: `relation` vs `transactionid` vs `tuple` — schema/DDL vs txn dài vs hàng nóng.

SQL Server gần ý: `sys.dm_os_wait_stats` (`LCK_M_*`) + `sys.dm_db_index_operational_stats` — không có view tên `pg_stat_lock`.

### 12.2 `log_lock_waits` mặc định on (19)

Trước 19 thường off — wait dài im lặng trừ khi bật. 19: **on**. Threshold vẫn quanh `deadlock_timeout`. Log ồn trên hệ tranh chấp nặng — lọc, đừng tắt mù rồi mất incident.

`deadlock_timeout` thấp = check cycle sớm *và* log wait sớm. Không hạ xuống 10ms production trừ khi đo.

---

## 13. Parallel autovacuum vs lock

Autovacuum 19 vacuum **index song song** (`autovacuum_max_parallel_workers`, storage `autovacuum_parallel_workers`). Worker lấy lock kiểu `VACUUM`: `SHARE UPDATE EXCLUSIVE` trên bảng — **tương thích** DML (`ROW EXCLUSIVE`), **không** tương thích `VACUUM` thứ hai, `CREATE INDEX CONCURRENTLY`, `VALIDATE CONSTRAINT`, `ANALYZE` một số pha, `REPACK (CONCURRENTLY)` copy.

Hệ quả vận hành:

- Parallel AV **không** chặn `SELECT`/`UPDATE` thường như `VACUUM FULL`.
- Tranh **I/O** với OLTP — cap worker. Scoring `pg_stat_autovacuum_scores` chọn bảng “đáng” trước (GUC `autovacuum_*_score_weight`).
- `ACCESS EXCLUSIVE` (DDL rewrite, `REPACK` swap, `LOCK TABLE`) vẫn đợi AV xong — AV song song kéo dài cửa sổ đợi.
- `idle in transaction` giữ xmin → AV chạy mà **không** dọn được tuple cần — parallel không chữa horizon.

```sql
SELECT * FROM pg_stat_autovacuum_scores;   -- 19
-- progress: started_by / mode trên vacuum progress (19)
```

SQL Server ghost cleanup không “parallel index vacuum” cùng mô hình; `REBUILD ONLINE` vs ghost là runbook khác. Đừng tắt autovacuum “cho nhanh” vì lock — đo `pg_stat_progress_vacuum` / wait `Lock`.

Scan query 19 đánh dấu page **all-visible** (trước: VACUUM / `COPY FREEZE`) — giảm heap fetch index-only, không giảm nhu cầu freeze wraparound.

### 13.1 Tương thích lock bảng (PostgreSQL)

Rút gọn: `ACCESS SHARE` tương thích mọi thứ trừ `ACCESS EXCLUSIVE`. `ROW EXCLUSIVE` (DML) xung đột `SHARE` / `SHARE ROW EXCLUSIVE` / `EXCLUSIVE` / `ACCESS EXCLUSIVE`. `SHARE UPDATE EXCLUSIVE` (VACUUM, CIC, VALIDATE, REPACK concurrent copy) xung đột chính nó và mọi mode nặng hơn.

```text
                    AS   RS   RE   SUE  S    SRE  E    AE
ACCESS SHARE        ·    ·    ·    ·    ·    ·    ·    X
ROW SHARE           ·    ·    ·    ·    ·    ·    X    X
ROW EXCLUSIVE       ·    ·    ·    ·    X    X    X    X
SHARE UPD EXCL      ·    ·    ·    X    X    X    X    X
SHARE               ·    ·    X    X    ·    X    X    X
SHARE ROW EXCL      ·    ·    X    X    X    X    X    X
EXCLUSIVE           ·    X    X    X    X    X    X    X
ACCESS EXCLUSIVE    X    X    X    X    X    X    X    X
```

Hệ quả: `CREATE INDEX` (không concurrent, `SHARE`) **chặn INSERT**. `VACUUM` không chặn INSERT. `REPACK` không concurrent = `AE` = chặn `SELECT`. Đừng đoán — đối chiếu docs `Explicit Locking`.

SQL Server không bảng 8 mode này: intent + S/U/X + Sch-S/Sch-M. `Sch-M` ≈ `ACCESS EXCLUSIVE` (chặn DML + SELECT schema).

### 13.2 Latch ≠ lock (SQL Server)

Latch bảo vệ cấu trúc bộ nhớ (trang buffer, PFS) — không phải khóa hàng nghiệp vụ. Wait `PAGELATCH_EX` trên PFS/GAM = tranh allocation `tempdb`/heap nóng, **không** chữa bằng `UPDLOCK`. `PAGEIOLATCH_*` = đợi đọc đĩa. Nhầm latch với deadlock 1205 → retry vô ích.

PostgreSQL: `LWLock` / `BufferPin` (19: wait event `BUFFER` đổi tên từ `BUFFERPIN`) — cùng họ “nội bộ”. `pg_stat_lock` không thay wait event I/O.

### 13.3 Hotspot một hàng / một page

Counter `UPDATE counters SET n = n + 1 WHERE id = 1` — mọi worker đợi **một** tuple (PG) hoặc **một** KEY/TID (SS). Optimized locking không nhân bản hàng. Parallel AV không giúp. Sửa: sharding counter, queue, `SEQUENCE`/`IDENTITY` nếu chỉ cần số tăng.

Last-page insert clustered SS (identity) vs btree PG: latch/page contention khác row lock — đo `PAGELATCH` / `LWLock:LockManager` / extend lock (`pg_stat_lock` `extend`).

---

## 14. Worked examples

### 14.1 RMW tồn kho

```sql
-- Atomic (ưu tiên, ít lock protocol)
UPDATE stock SET qty = qty - 1 WHERE sku = 'A' AND qty >= 1;

-- PostgreSQL
SELECT qty FROM stock WHERE sku = 'A' FOR UPDATE;

-- SQL Server
SELECT qty FROM dbo.Stock WITH (UPDLOCK, ROWLOCK) WHERE Sku = N'A';
```

### 14.2 Queue SKIP LOCKED

Xem mục 7. Worker loop: `BEGIN` → skip locked → xử lý → `COMMIT`. Lỗi: `ROLLBACK` hàng vẫn locked chỉ trong txn — sau rollback worker khác lấy được.

### 14.3 Deadlock hai session (đủ vòng)

Xem §8.1–8.3. Runbook:

1. Repro hai cửa sổ, dừng giữa hai `UPDATE`.
2. SS: XEvent deadlock graph — resource KEY `Accounts` id 1 vs 2.
3. PG: log `deadlock detected` + `40P01`.
4. Fix: `SELECT id FROM accounts WHERE id IN (1,2) ORDER BY id FOR UPDATE` (PG) / `WITH (UPDLOCK, HOLDLOCK) … ORDER BY Id` (SS) trước khi sửa.
5. App: retry jitter — không chỉ “catch và chạy lại câu thứ hai”.

### 14.4 1138 tempdb

```text
1. RG: GROUP_MAX_TEMPDB_DATA_MB = 1024 trên group báo cáo
2. Query hash join spill > 1 GB tempdb
3. Error 1138, severity 17
4. Không phải 1205; retry cùng query vẫn fail
5. Sửa: cap lớn hơn / MAXDOP / index / batch; hoặc spill ít hơn
```

### 14.5 Deadlock retry (pseudo)

```text
for attempt in 1..N:
    BEGIN
    try work
    COMMIT
    catch 1205 / 40P01 / 40001:
        ROLLBACK
        sleep exp + jitter
```

### 14.6 Incident: head blocker idle

```text
SS: dm_exec_requests blocking_session_id → session 55
    55: last_request_end_time 40 phút, open_transaction_count 1
    IMPLICIT_TRANSACTIONS hoặc ORM quên COMMIT
    Kill 55 có chủ đích; sửa pool

PG: pg_stat_activity state = idle in transaction, xact_start 40 phút
    xmin horizon đứng → VACUUM “chạy” không dọn
    idle_in_transaction_session_timeout; tìm app giữ BEGIN qua HTTP
```

### 14.7 Incident: log không truncate

```text
SS: log_reuse_wait_desc = REPLICATION / AVAILABILITY_REPLICA / CDC
    CES PREVIEW hoặc mirroring lag → .ldf phình
    Không shrink mù; sửa consumer / cap RG mirroring

PG: pg_replication_slots restart_lsn đứng, pg_wal đầy
    Drop slot chết; retain_dead_tuples + max_retention_duration
    Không REPACK trước khi horizon chạy
```

### 14.8 LAQ vs predicate không khớp

```sql
-- RCSI + optimized locking: hàng status='paid' không bị X chỉ vì cùng page
UPDATE dbo.Orders SET Status = N'closed' WHERE Status = N'open' AND Id = @id;
-- Hàng không khớp predicate: không X dài (LAQ)
-- REPEATABLE READ: LAQ không áp — vẫn giữ lock chống phantom
```

---

## 15. Best practices & checklist

- Txn ngắn; không I/O mạng trong lock.
- SS: RCSI + (2025) ADR + `OPTIMIZED_LOCKING` có chủ đích; đo blocking và 1205 trước/sau.
- PG: `idle_in_transaction_session_timeout`; monitor slot / xmin; 19: `pg_stat_lock` + log lock waits.
- RMW: atomic `UPDATE` hoặc `UPDLOCK` / `FOR UPDATE`.
- Queue: `SKIP LOCKED` / `READPAST+UPDLOCK`; không fairness.
- Thứ tự khóa toàn cục; retry jitter. Phân biệt 1205/`40P01` vs `40001`.
- Không `NOLOCK` tài chính.
- DDL: `CONCURRENTLY` / `ONLINE` / `NOT VALID`.
- Tempdb governor trên Standard 2025 cho workload spill; bắt 1138.
- CES/mirroring/slot: SLO lag; alert disk / `log_reuse_wait_desc`.
- Parallel AV: cap worker; đừng chồng `REPACK` swap giờ AV nặng.

---

## 16. Bẫy khi review

- `BEGIN` T-SQL không mở txn — [transactions.md](transactions.md).
- `FOR UPDATE` join không `OF alias`.
- `READPAST` thiếu `UPDLOCK` — lost job.
- Port `SKIP LOCKED` ↔ `NOLOCK`.
- `SET TRANSACTION ISOLATION` tưởng đủ lost update.
- Optimized locking = “không còn deadlock”.
- Escalation batch 50k hàng một `UPDATE`.
- Slot logical / CES / mirroring quên monitor log reuse.
- `LOCK_TIMEOUT` nuốt error, coi như 0 hàng.
- SSI retry không backoff → thundering herd.
- `NOLOCK` báo cáo tiền.
- Giữ cursor hold qua commit, tưởng còn khóa.
- `WAITFOR DELAY` vs `WAIT FOR` LSN.
- Tắt `log_lock_waits` vì ồn, mất tín hiệu.
- Parallel autovacuum = “chặn OLTP như VACUUM FULL”.
- 1138 xử lý như 1205 (retry mù).
- On-prem bật optimized locking không ADR/RCSI.

---

## 17. Version gates

| Mục | SQL Server | PostgreSQL |
|---|---|---|
| RCSI / SI | lâu | MVCC lâu |
| Optimized locking (TID + LAQ) | **2025** (on-prem off mặc định; Azure on) | — |
| Tempdb space governor (1138) | **2025** (RG cả Standard) | — |
| ADR tempdb | **2025** | — |
| `SKIP LOCKED` | `READPAST` lâu | 9.5+ |
| `pg_stat_lock` / `log_lock_waits` default on | — | **19** |
| `max_locks_per_transaction` default 128 | — | **19** |
| Parallel autovacuum index | ghost cleanup (khác mô hình) | **19** |
| CES | **2025 PREVIEW** | logical decoding |
| Fabric mirroring / log reuse | **2025 GA** (Synapse Link chết) | slot / `retain_dead_tuples` **19** |
| Sequence trên logical sub | — | **19** |
| `WAIT FOR` LSN | — | **19** |
| Deadlock | **1205** | **40P01**; SSI **40001** |

Isolation anomalies, SNAPSHOT 3960, FDW READ ONLY: [transactions.md](transactions.md).

---

## Phụ lục A. `pg_stat_lock` — đọc số

`locktype` = loại đối tượng (`relation`, `tuple`, `transactionid`, `page`, `extend`, `advisory`, …) — **không** phải `ACCESS EXCLUSIVE`. `waits` / `wait_time` chỉ tăng khi xin được lock sau wait **> deadlock_timeout**. Wait ngắn im. `fastpath_exceeded` → cân `max_locks_per_transaction` (19 default 128).

Reset: `pg_stat_reset` (toàn stats — cẩn thận). Dashboard: so sánh `relation` vs `transactionid` — DDL/bảng nóng vs txn dài.

`log_lock_waits` on 19: log ồn ≠ tắt; lọc application_name. Không nhầm dòng log wait với `deadlock detected` (`40P01`).

---

## Phụ lục B. Optimized locking — thứ tự bật/tắt

```text
Bật:  ADR ON → RCSI ON (nếu cần LAQ) → OPTIMIZED_LOCKING ON
Tắt:  OPTIMIZED_LOCKING OFF → rồi mới ADR OFF
On-prem mặc định off; Azure SQL luôn on
Không đổi SET TRANSACTION ISOLATION
Test: 1205 graph, blocking, version I/O, tempdb/PVS
Compat: engine 2025; không GUC PostgreSQL
```

LAQ không vào RR/SR. TID không thay `UPDLOCK` RMW. Schema lock nguyên.

---

## Phụ lục C. Hai session — thứ tự khóa mẫu

```sql
-- Cả hai dialect: khóa id tăng
BEGIN;  -- PG: BEGIN;  SS: BEGIN TRAN;
SELECT * FROM accounts WHERE id IN (1, 2) ORDER BY id
    FOR UPDATE;                              -- PG
-- SS: SELECT … WITH (UPDLOCK, HOLDLOCK, ROWLOCK) WHERE Id IN (1,2) ORDER BY Id;
UPDATE accounts SET balance = balance - 10 WHERE id = 1;
UPDATE accounts SET balance = balance + 10 WHERE id = 2;
COMMIT;
```

Không `ORDER BY` = planner có thể khóa 2 rồi 1 — deadlock với session ngược. Optimized locking không sắp thứ tự.

---
