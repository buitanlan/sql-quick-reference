# Giao dịch & isolation

> **Baseline:** SQL Server **2025** (17.x) · PostgreSQL **19**.  
> Isolation **không** portable. Cùng tên `REPEATABLE READ` trên hai engine **không** cùng guarantee — đây là nguồn bug hay gặp khi port.

SQL xử lý đồng thời bằng **transaction**: một đơn vị công việc hoặc thành công hết (`COMMIT`) hoặc không để lại hiệu ứng (`ROLLBACK`). Isolation quyết định *mình thấy gì của người khác* và *người khác thấy gì của mình* trước khi commit. Hai engine hiện thực isolation khác nhau (khóa vs MVCC/SSI) nên không thể copy `SET TRANSACTION ISOLATION LEVEL` rồi cho rằng hành vi giống nhau.

Khóa, wait, deadlock, tempdb/xmin: [concurrency.md](concurrency.md). Kiến trúc MVCC/WAL: [internal.md](internal.md). Temporal leftover: [constraints.md](constraints.md), [dml.md](dml.md).

---

## Mục lục

- [1. Tổng quan \& triết lý](#1-tổng-quan--triết-lý)
  - [1.1 Hình dung: isolation là “bản chụp”](#11-hình-dung-isolation-là-bản-chụp-không-phải-độ-mạnh)
- [2. Bắt đầu / kết thúc](#2-bắt-đầu--kết-thúc)
- [3. Autocommit \& implicit](#3-autocommit--implicit)
- [4. Isolation levels](#4-isolation-levels)
- [5. Hiện tượng đọc (anomalies)](#5-hiện-tượng-đọc-anomalies)
- [6. Lost update \& write skew](#6-lost-update--write-skew)
- [7. SQL Server: locking, RCSI, SNAPSHOT, ADR](#7-sql-server-locking-rcsi-snapshot-adr)
- [8. PostgreSQL: MVCC](#8-postgresql-mvcc)
- [9. Savepoint, XACT\_ABORT, abort](#9-savepoint-xact_abort-abort)
- [10. DDL trong transaction](#10-ddl-trong-transaction)
- [11. WAIT FOR LSN (PostgreSQL 19)](#11-wait-for-lsn-postgresql-19)
- [12. FDW READ ONLY (PostgreSQL 19)](#12-fdw-read-only-postgresql-19)
- [13. Retry 40001 / 1205](#13-retry-40001--1205)
- [14. Durability: COMMIT chưa chắc đĩa](#14-durability-commit-chưa-chắc-đĩa)
- [15. Worked examples](#15-worked-examples)
- [16. Best practices \& checklist](#16-best-practices--checklist)
- [17. Bẫy khi review](#17-bẫy-khi-review)
- [18. Version gates](#18-version-gates)

---

## 1. Tổng quan & triết lý

ACID trong thực tế engine:

- **Atomicity:** statement/txn hoặc commit hoặc rollback. SQL Server mặc định lỗi một statement *không* abort cả txn (`XACT_ABORT OFF`); PostgreSQL lỗi statement **abort cả txn** trừ khi có savepoint. Đây không phải “cùng SQL” — client port từ SS sang PG gặp `current transaction is aborted` ngay lệnh kế.
- **Consistency:** constraint + trigger được kiểm tra (immediate hoặc deferred). Isolation *không* thay constraint. Deferred PG kiểm lúc `COMMIT` — [constraints.md](constraints.md).
- **Isolation:** xem §4–§8. Đây là chỗ hai dialect lệch nhiều nhất.
- **Durability:** WAL / log flush theo `synchronous_commit` (PG) / delayed durability (SQL Server). `COMMIT` trả về chưa chắc đã xuống đĩa nếu cấu hình nới — §14.

Transaction nên **ngắn**: chỉ ôm phần đọc-ghi cần atomic. Giữ txn qua HTTP/UI/network chat = lock kéo dài (SQL Server) hoặc `idle in transaction` + `xmin` horizon (PostgreSQL).

Hai hợp đồng khác nhau:

```text
SQL Server (RCSI off)     PostgreSQL
─────────────────────     ─────────────────────────
Reader lấy S lock         SELECT thường không row-lock
Writer lấy X              Writer khóa tuple (xmax)
Version store = opt-in    Tuple cũ nằm trên heap
(RCSI/SI/ADR)             đến khi VACUUM
```

Đừng giải thích PostgreSQL bằng `NOLOCK`/`HOLDLOCK`, đừng giải thích SQL Server bằng “MVCC mặc định”. Optimized locking **2025** giảm lock memory — **không** biến SS thành PG. Chi tiết khóa: [concurrency.md](concurrency.md).

### 1.1 Hình dung: isolation là “bản chụp”, không phải “độ mạnh”

Isolation **không** phải thang 1–4 “càng cao càng đúng”. Nó trả lời một câu: *trong lúc tôi đang làm việc, tôi có được phép thấy (và bị ảnh hưởng bởi) thay đổi của người khác không?*

Hình dung hai người sửa **cùng một bảng tính** trên mạng:

| Bạn muốn | Đời thường | Isolation gần đúng |
|---|---|---|
| Thấy ô vừa bị người kia sửa, dù họ chưa bấm Lưu | Đọc nháp | `READ UNCOMMITTED` (chỉ SS; PG **không** cho) |
| Chỉ thấy ô đã Lưu; lần sau mở lại ô đó *có thể* đã đổi | Làm việc trên file sống | `READ COMMITTED` (mặc định cả hai) |
| Trong phiên của tôi, ô tôi đã đọc **không đổi** | Mở bản sao lúc bắt đầu, làm trên bản sao | PG `REPEATABLE READ` / SS `SNAPSHOT` |
| Cả *danh sách hàng* tôi đếm cũng không thêm hàng mới | Bản sao + không ai chèn vào vùng tôi đang đếm | PG `SERIALIZABLE` (SSI) / SS `SERIALIZABLE` (range lock) |

Hai engine **chụp bản sao khác nhau**:

```text
PostgreSQL (mặc định RC)
  Mỗi câu SELECT/UPDATE = một tấm ảnh mới.
  Câu 1 thấy balance=100. Người kia COMMIT 50.
  Câu 2 (cùng txn) thấy 50.  → “non-repeatable” là đúng thiết kế, không phải bug.

PostgreSQL RR / SERIALIZABLE
  Cả txn = một tấm ảnh lúc bắt đầu đọc.
  Câu 2 vẫn thấy 100. Nếu bạn UPDATE hàng đó sau khi người kia COMMIT
  → engine nói “ảnh của bạn lỗi thời” (40001), không lặng lẽ ghi đè.

SQL Server RC (chưa RCSI)
  Không chụp ảnh: muốn đọc thì cầm chìa khóa S trên ô đó một lúc.
  Người kia muốn sửa phải đợi bạn nhả. Bạn xong hàng là nhả — câu sau có thể thấy giá mới.

SQL Server RCSI
  Đọc = xem bản photocopy trong kho version; không cầm S.
  Người kia sửa ô thật. Bạn vẫn xem photocopy của *câu đang chạy*, không đợi.
```

**Hệ quả khi port:** copy `SET TRANSACTION ISOLATION LEVEL REPEATABLE READ` từ SS sang PG thì phantom *biến mất* (PG RR chặn phantom; SS RR thì không). Copy ngược lại: PG RR ≈ SS `SNAPSHOT`, **không** ≈ SS RR (khóa S).

Chi tiết anomaly: §5. Write skew (cả hai đọc đúng, ghi khác hàng, invariant vỡ): §6.2 — đây là chỗ “ảnh” không cứu được trừ SSI / range lock / constraint.

---

## 2. Bắt đầu / kết thúc

```sql
-- SQL Server
BEGIN TRANSACTION;                 -- hoặc BEGIN TRAN, BEGIN TRAN T1
COMMIT TRANSACTION;
ROLLBACK TRANSACTION;

-- PostgreSQL
BEGIN;                             -- hoặc START TRANSACTION / BEGIN TRANSACTION
COMMIT;
ROLLBACK;
```

PostgreSQL nhận `BEGIN ISOLATION LEVEL … READ ONLY` / `READ WRITE` / `DEFERRABLE` ngay lúc mở. SQL Server tách: `BEGIN TRAN` rồi `SET TRANSACTION ISOLATION LEVEL` (và `SET TRANSACTION READ ONLY` **không** có trên T-SQL theo nghĩa PG).

### 2.1 `BEGIN` T-SQL không phải transaction

```sql
BEGIN                          -- chỉ mở khối lệnh
    SELECT 1;
END;
-- Không có transaction. @@TRANCOUNT vẫn 0.
```

Muốn mở txn phải `BEGIN TRAN` / `BEGIN TRANSACTION`. Đây là bẫy khi đọc code từ PostgreSQL (`BEGIN;` = mở txn).

### 2.2 Lồng nhau — ngữ nghĩa khác nhau

**SQL Server** dùng `@@TRANCOUNT`. `BEGIN TRAN` lặp lại chỉ tăng counter; `COMMIT` giảm 1; **chỉ commit thật khi counter về 0**. `ROLLBACK` (không tên) về 0 ngay — nuốt mọi mức lồng.

```sql
BEGIN TRAN;                     -- @@TRANCOUNT = 1
    BEGIN TRAN;                 -- @@TRANCOUNT = 2
    INSERT INTO t VALUES (1);
    COMMIT;                     -- @@TRANCOUNT = 1  — chưa durable
COMMIT;                         -- @@TRANCOUNT = 0  — mới ghi log
```

`ROLLBACK TRAN savepoint` chỉ về savepoint. `ROLLBACK` không tên hủy cả stack. Stored proc `COMMIT` khi caller vẫn `@@TRANCOUNT = 2` = **không** durable — caller tưởng đã xong.

**PostgreSQL** không có nested transaction thật. `BEGIN` trong txn đang mở là lỗi (trừ protocol/client giả lập). Dùng **savepoint** để rollback từng phần.

```sql
BEGIN;
INSERT INTO t VALUES (1);
SAVEPOINT sp1;
INSERT INTO t VALUES (2);
ROLLBACK TO SAVEPOINT sp1;      -- mất hàng 2, giữ hàng 1
COMMIT;                         -- chỉ còn hàng 1
```

### 2.3 Đọc trạng thái

```sql
-- SQL Server
SELECT @@TRANCOUNT, XACT_STATE();
-- XACT_STATE(): 1 = commitable, 0 = không txn, -1 = uncommittable (cần rollback)

-- PostgreSQL
SELECT txid_current();                    -- gán xid nếu chưa có (cẩn thận: đừng gọi vô tội vạ)
SELECT pg_current_xact_id_if_assigned();  -- NULL nếu txn mới chưa xin xid
```

`XACT_STATE() = -1` (doomed): chỉ `ROLLBACK` được. Thường gặp sau lỗi nghiêm khi `XACT_ABORT ON`, hoặc trigger fail, hoặc một số lỗi compile/batch. `CATCH` rồi `COMMIT` lúc này → lỗi 3930 / không commit được.

### 2.4 Transaction có tên (SQL Server)

```sql
BEGIN TRAN PayInvoice;
-- …
COMMIT TRAN PayInvoice;
-- ROLLBACK TRAN PayInvoice;   -- chỉ đúng nếu đó là savepoint hoặc tên khớp mức hiện tại
```

Tên txn **không** tạo nested thật. `ROLLBACK TRAN PayInvoice` khi `PayInvoice` là tên txn ngoài cùng = rollback cả stack. Nhầm tên savepoint với tên txn = rollback quá tay.

### 2.5 `COMMIT AND CHAIN` (PostgreSQL)

```sql
BEGIN ISOLATION LEVEL REPEATABLE READ;
-- việc 1
COMMIT AND CHAIN;     -- commit, mở txn mới cùng isolation / read-only / deferrable
-- việc 2
COMMIT;
```

Tiện pipeline cùng session. SQL Server không có tương đương trực tiếp — phải `COMMIT` rồi `BEGIN TRAN` + `SET TRANSACTION` lại (và implicit tran có thể đã mở).

---

## 3. Autocommit & implicit

Cả hai engine: mỗi statement ngoài txn tường minh = **một** transaction (autocommit). Driver có thể phá mặc định này.

| Cơ chế | Hành vi | Nguy cơ |
|---|---|---|
| Autocommit (mặc định) | Mỗi `INSERT`/`UPDATE` tự commit | An toàn hơn cho ad-hoc |
| SQL Server `SET IMPLICIT_TRANSACTIONS ON` | `SELECT`/`INSERT`/… tự `BEGIN TRAN` | Session giữ lock đến `COMMIT` tường minh |
| JDBC/ODBC `autoCommit=false` | Client mở txn dài | Quên commit → lock / idle-in-txn |
| `SET IMPLICIT_TRANSACTIONS OFF` | SQL Server về autocommit | |
| pgjdbc `preferQueryMode` / simple vs extended | Nhiều statement một simple query = một txn | Lỗi giữa chừng abort cả batch PG |

```sql
-- SQL Server: kiểm tra
SELECT CASE WHEN @@OPTIONS & 2 = 2 THEN 'implicit ON' ELSE 'implicit OFF' END;
```

**Ghi chú:** ORM (EF, Hibernate, Dapper transaction) thường tắt autocommit. Connection pool trả session còn txn mở là incident cổ điển — luôn `COMMIT`/`ROLLBACK` trong `finally`, hoặc dùng scope (`TransactionScope`, `pgx.Begin`). SS implicit + pool = lock overnight. PG `idle_in_transaction_session_timeout` bắt session quên — [concurrency.md](concurrency.md).

---

## 4. Isolation levels

```sql
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;   -- SQL Server ≈ NOLOCK
```

PostgreSQL cũng nhận các tên trên, nhưng **ánh xạ nội bộ khác**:

| Level bạn viết | SQL Server (khóa, chưa RCSI) | PostgreSQL |
|---|---|---|
| `READ UNCOMMITTED` | Dirty read được phép | **Treated as READ COMMITTED** — không dirty |
| `READ COMMITTED` | Mặc định. Shared lock ngắn trên hàng đọc | Mặc định. Snapshot **từng statement** |
| `REPEATABLE READ` | Giữ S lock đến cuối txn. Phantom **vẫn có thể** | Snapshot **cả transaction**. Phantom không. Gần SI |
| `SERIALIZABLE` | Key-range lock (S/X + range) | **SSI**: không khóa range; phát hiện conflict rồi abort `40001` |
| `SNAPSHOT` | Opt-in (`ALLOW_SNAPSHOT_ISOLATION`) | Không có tên này; RR đã là snapshot txn |

```sql
-- SQL Server: bật row-versioning ở mức database
ALTER DATABASE Sales SET READ_COMMITTED_SNAPSHOT ON;   -- RCSI: RC dùng version
ALTER DATABASE Sales SET ALLOW_SNAPSHOT_ISOLATION ON;  -- cho phép SET ... SNAPSHOT
```

`READ_COMMITTED_SNAPSHOT` đổi **mặc định** `READ COMMITTED` sang đọc version (không lấy S lock). Đây là thay đổi hành vi lớn — đo blocking/`tempdb` (hoặc ADR version store) trước khi bật production.

PostgreSQL:

```sql
BEGIN ISOLATION LEVEL REPEATABLE READ;
-- hoặc
SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
SET TRANSACTION READ ONLY DEFERRABLE;   -- SSI read-only: chờ snapshot “an toàn”, ít abort
```

`SET TRANSACTION` phải là **lệnh đầu** trong txn (sau `BEGIN`, trước DML). Đặt sau `SELECT` → lỗi hoặc không áp dụng như ý.

`READ ONLY DEFERRABLE` (PG, SERIALIZABLE): session có thể **đợi** đến khi có snapshot không conflict, rồi đọc. Không ghi. Không tương đương SS `SNAPSHOT` + hint.

---

## 5. Hiện tượng đọc (anomalies)

| Hiện tượng | Ý nghĩa | RU | RC | RR | SR |
|---|---|---|---|---|---|
| Dirty read | Đọc dữ liệu **chưa commit** của txn khác | SS: có · PG: không | không | không | không |
| Non-repeatable read | Cùng hàng, đọc 2 lần ra 2 giá trị | có | có (RC) | không | không |
| Phantom | Lần 2 `SELECT` thấy hàng **mới** khớp predicate | có | có | SS: có · PG: không | không |
| Write skew | Hai txn đọc tập chồng, ghi phần không chồng, cả hai commit — invariant vỡ | — | có | có (trừ SSI) | SSI / range-lock |

### 5.1 Non-repeatable — ví dụ

```text
T1: SELECT balance FROM accounts WHERE id = 1;     -- 100
T2: UPDATE accounts SET balance = 50 WHERE id = 1; COMMIT;
T1: SELECT balance FROM accounts WHERE id = 1;     -- RC: 50; RR/SI: 100
```

### 5.2 Phantom — ví dụ

```text
T1: SELECT COUNT(*) FROM orders WHERE status = 'open';   -- 3
T2: INSERT INTO orders (status) VALUES ('open'); COMMIT;
T1: SELECT COUNT(*) FROM orders WHERE status = 'open';
    SQL Server RR: có thể 4 (không range lock)
    PostgreSQL RR: 3
    SERIALIZABLE: 3 hoặc T2/T1 abort
```

### 5.3 Dirty read chỉ SQL Server RU

```sql
-- Session A
BEGIN TRAN;
UPDATE dbo.Accounts SET Balance = 0 WHERE Id = 1;
-- chưa COMMIT

-- Session B
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SELECT Balance FROM dbo.Accounts WHERE Id = 1;   -- 0, có thể bị rollback
```

PostgreSQL `READ UNCOMMITTED` **không** làm được chuyện này — vẫn RC.

**Ghi chú:** Tên isolation ANSI (1992) không mô tả hết snapshot / SSI. Đừng thiết kế dựa trên bảng “chuẩn” rồi đoán PostgreSQL RR giống SQL Server RR.

---

## 6. Lost update & write skew

### 6.1 Lost update

```text
T1: SELECT qty FROM stock WHERE sku = 'A';          -- 10
T2: SELECT qty FROM stock WHERE sku = 'A';          -- 10
T1: UPDATE stock SET qty = 9 WHERE sku = 'A'; COMMIT;
T2: UPDATE stock SET qty = 8 WHERE sku = 'A'; COMMIT;   -- ghi đè, mất lần trừ của T1
```

Cách đúng — **atomic** hoặc khóa:

```sql
-- Atomic (ưu tiên)
UPDATE stock SET qty = qty - 1 WHERE sku = 'A' AND qty >= 1;

-- PostgreSQL: khóa hàng rồi tính
SELECT qty FROM stock WHERE sku = 'A' FOR UPDATE;

-- SQL Server
SELECT qty FROM dbo.Stock WITH (UPDLOCK, ROWLOCK, HOLDLOCK) WHERE Sku = 'A';
```

`HOLDLOCK` = serializable hint trên phạm vi câu lệnh (giữ S/range). `UPDLOCK` lấy U lock để không bị convert deadlock với writer khác.

RCSI **không** sửa lost update: reader không S, hai writer vẫn có thể đọc-tính-ghi. Optimized locking **không** thêm optimistic concurrency — vẫn cần `UPDLOCK` hoặc `UPDATE` atomic.

PostgreSQL RR: T2 `UPDATE` hàng T1 đã sửa → `40001` concurrent update. Đó là bảo vệ; app phải retry, không nuốt.

### 6.2 Write skew — hai người đều “thấy còn một”, cùng bước ra

Lost update (§6.1) là **cùng một ô**: hai người trừ kho, người sau đè người trước. Write skew **không đụng cùng hàng** — vì vậy RR/RCSI/`FOR UPDATE` một hàng *không* thấy vấn đề.

Invariant nghiệp vụ: ca trực phải còn **≥ 1** người `active`.

```text
Bảng on_call:  Ada active=1,  Bob active=1     (đếm = 2)

T1 đọc: “còn 2, mình off được”
T2 đọc: “còn 2, mình off được”
T1 ghi Ada=0, COMMIT          — còn Bob, invariant còn đúng
T2 ghi Bob=0, COMMIT          — còn 0. Không ai đụng hàng của ai.
                              Engine RR: “mỗi người sửa hàng khác → OK”
```

Đây không phải dirty read, không phải lost update (Ada vẫn là 0, Bob vẫn là 0 — không ai bị đè). Invariant **toàn cục** vỡ vì mỗi txn chỉ nhìn snapshot của mình.

```text
         Ada          Bob
T0       1            1
T1 đọc   ───────── đếm=2 ─────────
T2 đọc   ───────── đếm=2 ─────────
T1 ghi   0            1
T2 ghi   0            0     ← không conflict từng hàng
```

Chặn bằng gì:

| Cách | Cơ chế | Nhược |
|---|---|---|
| PG `SERIALIZABLE` (SSI) | Engine nhớ “T1 đọc tập active, T2 ghi Bob ∈ tập đó” → abort một bên `40001` | App phải retry; không phải lock range |
| SS `SERIALIZABLE` | Key-range / predicate lock trên `active=1` | Predicate phức tạp có thể **không** khóa đủ — test |
| Constraint / một hàng `on_call_count` | Một chỗ ghi, unique/check | Đổi schema |
| `UPDATE … WHERE (SELECT COUNT(*) FILTER (WHERE active)) > 1` | Atomic trên engine | Vẫn cần isolation/khóa đúng; test race |

RCSI/SI **không** chặn write skew: cả hai thấy photocopy “còn 2”, ghi hai hàng khác, commit. `UPDLOCK` trên *một* bác sĩ cũng không đủ — phải khóa **cả tập** đang đọc, hoặc SSI, hoặc một counter.

**Ghi chú:** Khi review “trừ tồn kho” → lost update (§6.1). Khi review “chỉ được off nếu còn người khác” / “hai tài khoản tổng ≥ 0” → write skew. Đừng chữa write skew bằng RCSI.

---

## 7. SQL Server: locking, RCSI, SNAPSHOT, ADR

### 7.1 Pessimistic (mặc định, RCSI off)

Reader lấy **S** lock, writer lấy **X**. Reader block writer và ngược lại trên cùng resource. `READ COMMITTED` nhả S khi *xong từng hàng* (không giữ hết scan). `REPEATABLE READ` giữ S đến `COMMIT`.

### 7.2 RCSI

`READ_COMMITTED_SNAPSHOT ON`: `READ COMMITTED` đọc **bản version** (row versioning trong `tempdb` / ADR). Reader **không** lấy S → không block writer. Writer-writer vẫn X-lock.

Hệ quả:

- Báo cáo nặng bớt block OLTP.
- `tempdb` I/O tăng (trừ khi version store trong ADR — Persistent Version Store).
- Trigger/`OUTPUT` vẫn thấy dữ liệu theo rule riêng — đừng giả định “như SNAPSHOT cả txn”.
- RCSI **per database**; AG: bật trên primary, không tự bật SI.

### 7.3 SNAPSHOT isolation

Cả txn thấy một snapshot lúc `BEGIN` (lần đầu đọc). Ghi đụng hàng người khác đã commit → error **3960**, phải rollback/retry. Gần PostgreSQL `REPEATABLE READ`.

```sql
SET TRANSACTION ISOLATION LEVEL SNAPSHOT;
```

Cần `ALLOW_SNAPSHOT_ISOLATION ON`. Khác RCSI: RCSI chỉ áp cho statement ở level RC; SNAPSHOT là cả txn và bắt update conflict.

### 7.4 ADR — chỗ để version + recovery

`ACCELERATED_DATABASE_RECOVERY` (2019+, **tempdb ADR = 2025**):

- Recovery nhanh (sLRU + PVS): rollback txn lớn không quét log cũ như trước.
- Version store **trong user DB** (PVS) thay vì `tempdb` khi RCSI/SI — giảm tranh tempdb.
- **2025:** ADR trong **tempdb** — recovery temp table, log truncate mạnh hơn.

```sql
ALTER DATABASE Sales SET ACCELERATED_DATABASE_RECOVERY = ON;
-- tempdb (2025):
ALTER DATABASE tempdb SET ACCELERATED_DATABASE_RECOVERY = ON;
```

Optimized locking **cần ADR** (TID). LAQ **cần RCSI**. Thứ tự bật: ADR → RCSI → `OPTIMIZED_LOCKING`. Tắt ADR phải tắt optimized locking trước. Không đổi isolation. Chi tiết TID/LAQ: [concurrency.md](concurrency.md) §4.

### 7.5 NOLOCK / READ UNCOMMITTED

Dirty read, đọc hai lần một hàng, bỏ hàng đang move page. **Không** dùng cho tiền, tồn kho, quyết định ghi. “Nhanh” không bù inconsistency. Ưu tiên RCSI.

### 7.6 Isolation không thay constraint

`NOLOCK` vẫn fail FK/CHECK lúc ghi. `SNAPSHOT` vẫn đụng unique lúc commit. Isolation ≠ “tắt rule”.

---

## 8. PostgreSQL: MVCC

### 8.0 Hình dung: không tẩy ô, chỉ thêm tờ mới

SQL Server (không RCSI) gần với “sửa tại chỗ + khóa cửa”. PostgreSQL gần với **sổ tay không tẩy**: mỗi lần sửa là viết **dòng mới**, dòng cũ gạch `xmax` = “hết hiệu lực khi txn này commit”. Người đọc cầm **tấm ảnh** (snapshot): chỉ thấy dòng có `xmin` đã commit trước ảnh, và `xmax` chưa commit (hoặc commit sau ảnh).

Vì thế `SELECT` không cần chìa khóa trên hàng — họ không đụng dòng người khác đang viết; họ đọc dòng *cũ hơn* trên heap. Người ghi **cùng một hàng** vẫn phải xếp hàng (tuple lock): không hai txn cùng gắn `xmax` lên một bản live.

Bảng phình vì dòng cũ nằm đó đến `VACUUM`. Đó không phải fragmentation kiểu `REORGANIZE` — là **lịch sử còn trên đĩa**. [internal.md](internal.md) §10.

Mỗi hàng (tuple) có `xmin` (txn tạo) / `xmax` (txn xóa hoặc cập nhật). `UPDATE`/`DELETE` **không ghi đè tại chỗ**: tạo tuple mới, gắn `xmax` lên bản cũ. `SELECT` thường **không** lấy row lock; chỉ thấy tuple visible theo snapshot.

```text
Heap sau UPDATE id=1 (xmin/xmax rút gọn):

  [tuple v1]  xmin=100  xmax=200   ← dead khi 200 commit, VACUUM chưa chạy
  [tuple v2]  xmin=200  xmax=0     ← bản hiện tại
```

HOT update (cùng page, không đụng cột index): bản mới cùng page, index không sửa. Hết chỗ / đụng index = tuple mới chỗ khác + dead — bloat.

### 8.1 Snapshot theo level

- **READ COMMITTED:** mỗi *statement* lấy snapshot mới. Sau khi đợi lock, statement **re-check** predicate trên bản mới — `UPDATE` có thể “mất” hàng vừa bị người khác đổi/xóa.
- **REPEATABLE READ / SERIALIZABLE:** một snapshot cho cả txn. Hàng bị người khác đổi → `could not serialize access due to concurrent update` (`40001`).

```
ERROR:  could not serialize access due to concurrent update
SQLSTATE: 40001
```

Retry cả transaction từ đầu (đọc lại). Temporal `FOR PORTION OF` dễ race hơn ở RC — xem [dml.md](dml.md), leftover + `WITHOUT OVERLAPS`: [constraints.md](constraints.md).

SSI thêm *si* (serialization anomaly): write skew abort dù không đụng cùng tuple. Mã vẫn `40001`, message khác (`reason code` trong log: `pivot` / `rw-conflict`).

### 8.2 Visibility & vacuum

Dead tuple chỉ thu hồi khi không còn snapshot nào còn thấy chúng. Transaction mở lâu / replication slot / prepared xact giữ **xmin horizon** → bloat.

```sql
SELECT pid, state, xact_start, wait_event
FROM pg_stat_activity
WHERE state = 'idle in transaction';
```

`VACUUM` / autovacuum dọn dead tuple. PG 19: parallel autovacuum, scoring (`pg_stat_autovacuum_scores`), scan có thể đánh dấu page all-visible. Bloat nặng: `REPACK (CONCURRENTLY)` — [indexes.md](indexes.md), [ddl.md](ddl.md). Parallel AV vs lock: [concurrency.md](concurrency.md).

### 8.3 `now()` vs đồng hồ

`now()` / `CURRENT_TIMESTAMP` / `transaction_timestamp()` = **thời điểm bắt đầu txn** (ổn định trong txn). `statement_timestamp()` đổi theo statement. `clock_timestamp()` đổi liên tục. Đừng dùng `clock_timestamp()` làm khóa nghiệp vụ.

SQL Server `SYSDATETIME()` / `GETDATE()` = tường hiện tại (không “đóng băng” lúc `BEGIN TRAN` trừ khi tự gán biến). Port `now()` sang T-SQL phải quyết: biến `@now` lúc mở txn, hay `SYSUTCDATETIME()` mỗi câu.

---

## 9. Savepoint, XACT_ABORT, abort

Đây là lệch **atomic** hay gặp nhất khi port.

```sql
-- SQL Server
SAVE TRANSACTION sp1;
ROLLBACK TRANSACTION sp1;

-- PostgreSQL
SAVEPOINT sp1;
ROLLBACK TO SAVEPOINT sp1;
RELEASE SAVEPOINT sp1;
```

### 9.1 Lỗi statement — khác nhau

**SQL Server** (`XACT_ABORT OFF`, mặc định): lỗi constraint thường chỉ abort *statement*; txn vẫn mở, `@@TRANCOUNT` giữ. Dễ commit nhầm phần còn lại.

```sql
SET XACT_ABORT OFF;         -- mặc định
BEGIN TRAN;
INSERT INTO t VALUES (1);   -- OK
INSERT INTO t VALUES (1);   -- PK fail: statement abort, @@TRANCOUNT vẫn 1
INSERT INTO t VALUES (2);   -- vẫn chạy!
COMMIT;                     -- 1 và 2 được commit — PK fail bị nuốt
```

```sql
SET XACT_ABORT ON;          -- khuyến nghị: lỗi → rollback cả txn
BEGIN TRAN;
INSERT …;
UPDATE …;                   -- nếu fail, cả txn doomed (XACT_STATE = -1)
COMMIT;                     -- fail; phải ROLLBACK
```

Try/catch:

```sql
SET XACT_ABORT ON;
BEGIN TRY
    BEGIN TRAN;
    -- …
    COMMIT;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK;
    THROW;
END CATCH;
```

`XACT_ABORT OFF` + `CATCH` không `ROLLBACK` = txn treo. `XACT_ABORT ON` + `CATCH` + `COMMIT` khi doomed = lỗi.

**PostgreSQL:** lỗi → txn **aborted**. Mọi lệnh sau (trừ `ROLLBACK` / `ROLLBACK TO`) báo `current transaction is aborted`. Client phải rollback hoặc rollback to savepoint.

```sql
BEGIN;
SAVEPOINT sp;
INSERT INTO t VALUES (1);
-- lỗi unique
ROLLBACK TO SAVEPOINT sp;
INSERT INTO t VALUES (2);
COMMIT;
```

PL/pgSQL `BEGIN … EXCEPTION` tạo savepoint ẩn quanh block — nuốt lỗi *trong function*, không tự commit.

### 9.2 Bảng so sánh abort

| | SQL Server `XACT_ABORT OFF` | SQL Server `XACT_ABORT ON` | PostgreSQL |
|---|---|---|---|
| Unique/FK fail | Abort statement | Abort txn (doomed) | Abort txn |
| Lệnh sau lỗi | Chạy tiếp | Không (cần rollback) | Lỗi “aborted” |
| `CATCH`/`EXCEPTION` | Có; phải tự rollback | Doomed; chỉ rollback | Savepoint / `EXCEPTION` |
| Batch compile fail | Tùy | Tùy | Cả script (psql) tùy `ON_ERROR_STOP` |

Port proc SS “insert thử, nếu trùng thì update” **không** `XACT_ABORT` sang PG: phải `ON CONFLICT` hoặc savepoint — đừng `INSERT` rồi bắt exception ở client rồi `UPDATE` cùng txn chưa rollback.

### 9.3 Driver

ADO.NET `SqlException` Number **2627** (unique) / **547** (FK) — txn có thể còn sống nếu `XACT_ABORT OFF`. Npgsql `PostgresException.SqlState` `23505` — txn **chết**. ORM “catch unique then continue” trên PG = mọi lệnh sau fail cho đến rollback.

---

## 10. DDL trong transaction

**PostgreSQL:** hầu hết DDL transactional. `CREATE TABLE` + `ROLLBACK` → bảng biến mất. Ngoại lệ: `VACUUM`, `CREATE INDEX CONCURRENTLY`, `REINDEX CONCURRENTLY`, `REPACK`, `ALTER TYPE … ADD VALUE` (một số ngữ cảnh lịch sử) — **không** trong transaction block.

**SQL Server:** nhiều DDL gây commit ngầm (`CREATE DATABASE` không nằm trong user txn hữu ích). `CREATE INDEX` lớn khó gói rollback sạch. Đừng giả định “DDL như DML”.

Hai engine đều lấy **schema lock** mạnh khi DDL — chặn DML. Production: `CONCURRENTLY` / `ONLINE = ON` / `NOT VALID` + `VALIDATE`.

`WAIT FOR` (§11) **không** chạy trong function/`DO` — cũng không phải DDL, nhưng cùng họ “top-level only”.

---

## 11. WAIT FOR LSN (PostgreSQL 19)

Read-your-writes trên **hot standby** (và vài chế độ flush): ghi primary, lấy LSN, trên standby chờ WAL tới điểm đó rồi `SELECT`.

Cú pháp docs 19:

```sql
WAIT FOR LSN 'lsn'
    [ WITH ( option [, ...] ) ]

-- option:
--   MODE 'mode'
--   TIMEOUT 'timeout'
--   NO_THROW
-- mode:
--   standby_replay | standby_write | standby_flush | primary_flush
```

Mặc định `MODE` = `standby_replay` (WAL đã **áp** trên standby → query thấy dữ liệu).

```sql
-- Primary, sau COMMIT (hoặc sau DML nếu synchronous_commit=off: dùng insert LSN)
SELECT pg_current_wal_insert_lsn();          -- ví dụ 0/306EE20
-- Durability trên primary: pg_current_wal_flush_lsn()

-- Standby (top-level, isolation ≤ READ COMMITTED)
WAIT FOR LSN '0/306EE20';
-- tương đương
WAIT FOR LSN '0/306EE20' WITH (MODE 'standby_replay');
SELECT * FROM orders WHERE id = 42;
```

### 11.1 MODE

| MODE | Chờ gì | Chạy ở |
|---|---|---|
| `standby_replay` (mặc định) | Replay xong; `pg_last_wal_replay_lsn()` ≥ LSN. **Cần cho RYW** | Standby (đang recovery) |
| `standby_flush` | WAL đã flush đĩa standby — bền, **chưa** chắc đã apply | Standby |
| `standby_write` | WAL đã write (có thể còn OS buffer) — nhanh, yếu durability | Standby |
| `primary_flush` | WAL flush trên **primary**; `pg_current_wal_flush_lsn()` ≥ LSN | Primary (không recovery) |

`standby_flush` / `standby_write` **không** đủ để `SELECT` thấy hàng vừa ghi — chỉ biết replica đã nhận/ghi WAL. Sai MODE = “chờ xong vẫn stale read”.

Sai chỗ chạy: `standby_*` trên primary (hoặc ngược) → lỗi, trừ `NO_THROW` trả `not in recovery`.

### 11.2 TIMEOUT và NO_THROW

Không `TIMEOUT` (hoặc 0) = chờ vô hạn — **không** dùng production không ngân sách.

```sql
WAIT FOR LSN '0/306EE20' WITH (TIMEOUT '100ms', NO_THROW);
-- status: success | timeout | not in recovery
```

Timeout không `NO_THROW` → `ERROR` (timed out while waiting…). Promotion lúc chờ standby mode → lỗi, hoặc `not in recovery` nếu `NO_THROW`. App: timeout/promotion → đọc primary, đừng giả sử replica đã kịp.

`TIMEOUT` nhận ms số nguyên hoặc literal có đơn vị (`'0.1s'`, `'100ms'`).

### 11.3 Ràng buộc (đừng bịa)

Docs 19:

- **Top-level command** — không gọi từ function, procedure, `DO`.
- Không snapshot đang giữ: **không** isolation cao hơn `READ COMMITTED` (RR/SSI giữ snapshot).
- So sánh **số** LSN, không timeline. Cascade + timeline switch: `success` có thể là LSN timeline khác — app tự đối chiếu timeline nếu cần.
- Standby: recovery conflict có thể cắt session `WAIT FOR` (ví dụ drop tablespace). Retry hoặc fallback primary.

SQL Server AG: **không** có `WAIT FOR LSN`. Sync commit đắt (secondary cứng trước khi `COMMIT` trả). Async = stale; app retry / không RYW. `WAITFOR DELAY` T-SQL **khác hẳn** (sleep). CES / mirroring không thay isolation.

**Ghi chú:** Lấy LSN **sau** thay đổi (sau `COMMIT` nếu `synchronous_commit=on`; `pg_current_wal_insert_lsn()` nếu delayed). Đưa LSN qua app/pool — replica không tự biết “commit của session kia”.

---

## 12. FDW READ ONLY (PostgreSQL 19)

`postgres_fdw` mở txn **remote** khớp local: isolation (SR → remote SR, còn lại remote RR), **READ ONLY / READ WRITE**, **DEFERRABLE / NOT DEFERRABLE**.

Trước 19: remote thường **READ WRITE** dù local `READ ONLY` — job “txn read-only nhưng upsert FDW” chạy được. **19:** local `READ ONLY` → remote `READ ONLY` → **không ghi** bảng foreign.

```sql
BEGIN READ ONLY;
UPDATE ft SET v = 1;     -- ft = foreign table postgres_fdw
-- ERROR: cannot execute UPDATE in a read-only transaction  (remote)
COMMIT;
```

ETL / “read-only user nhưng ghi staging remote” phải txn **READ WRITE**. Login trigger trên remote **vẫn có thể ghi** (docs: READ ONLY local không chặn trigger login remote).

`DEFERRABLE` đẩy sang remote: SSI read-only deferrable ít abort remote; góc cạnh (cursor mở trước `SET TRANSACTION`, trigger deferred remote) — đặt mode **trước** lần chạm foreign table đầu.

SQL Server linked server **không** thừa `READ ONLY` kiểu này. `BEGIN TRAN` local + `UPDATE` four-part vẫn ghi remote theo quyền linked — isolation linked ≠ isolation local.

**Ghi chú:** Breaking 19. Test mọi job `SET TRANSACTION READ ONLY` + `postgres_fdw`. `CREATE SUBSCRIPTION … SERVER` (19) dùng tham số `postgres_fdw` — khác DML FDW, đừng trộn.

---

## 13. Retry 40001 / 1205

Retry **cả transaction** (đọc lại), không chỉ statement cuối.

| Engine | Khi nào | Mã | Ghi chú |
|---|---|---|---|
| PostgreSQL | SSI, concurrent update RR/SR | **`40001`** | Serialization / concurrent update |
| PostgreSQL | Deadlock lock wait | **`40P01`** | `deadlock detected` |
| SQL Server | Deadlock | **`1205`** | Severity 13; victim rollback sẵn |
| SQL Server SNAPSHOT | Update conflict | **`3960`** | Cần rollback/retry |
| SQL Server | Lock timeout | **`1222`** | `LOCK_TIMEOUT`; không deadlock |
| SQL Server | RCSI version cleanup (hiếm) | **`3950`+** | Đối chiếu Learn; đừng bịa |

```text
for attempt in 1..N:
    BEGIN
    try work          -- đọc lại hết; không tái sử dụng giá trị statement trước
    COMMIT
    catch 40001 / 40P01 / 1205 / 3960:
        ROLLBACK      -- PG bắt buộc; SS 1205 engine đã rollback victim
        sleep backoff (exp + jitter)
```

### 13.1 SQL Server 1205

Victim **đã** rollback. `XACT_ABORT ON`: doomed. Retry = `BEGIN TRAN` mới. `CATCH` 1205 rồi `COMMIT` = sai. Đo graph: Extended Events `xml_deadlock_report` — [concurrency.md](concurrency.md) §8.

Optimized locking đổi *lifetime* lock → graph có thể khác; **không** hết vòng A→B / B→A. Test 1205 trước/sau khi bật.

### 13.2 PostgreSQL 40001 vs 40P01

`40P01` = vòng khóa (giống 1205). `40001` = SSI hoặc RR concurrent update — **không** có lock cycle. Cùng retry, khác nguyên nhân: hotspot SSI không chữa bằng “thứ tự khóa”; cần atomic `UPDATE` / hàng counter / giảm isolation nếu invariant cho phép.

### 13.3 XACT_ABORT và retry

`XACT_ABORT OFF` + unique 2627: txn **còn**. Retry “cả txn” mà không rollback = ghi đôi phần đầu. PG: sau `23505` txn chết — bắt buộc rollback; đừng map 2627 → 23505 1-1 về *trạng thái txn*.

Thiếu jitter + nhiều worker → thundering herd. Hot row: đừng SSI retry mù — redesign.

`postgres_fdw` 19: serialization fail có thể đến từ **remote** RR/SR. Retry local phải retry remote (cùng txn — abort cả hai). Txn local `READ ONLY` không “ghi xong rồi retry ghi”.

---

## 14. Durability: COMMIT chưa chắc đĩa

| | SQL Server | PostgreSQL |
|---|---|---|
| Mặc định | Flush log lúc commit | `synchronous_commit = on` |
| Nới | Delayed durability (`DELAYED_DURABILITY`) | `synchronous_commit = off` / `local` |
| Sync replica | AG sync | `synchronous_commit = remote_apply` / `on` + `synchronous_standby_names` |
| RYW replica async | Không `WAIT FOR` LSN | `WAIT FOR` `standby_replay` |

Delayed durability / `synchronous_commit=off`: `COMMIT` trả về, crash có thể mất txn cuối. `WAIT FOR MODE primary_flush` (PG 19) chờ flush trên primary — không thay `synchronous_commit=on` cho mọi session, nhưng cho phép app chọn điểm bền.

SQL Server delayed durability + AG: đọc Learn (không bịa tương tác optimized locking).

---

## 15. Worked examples

### 15.1 Trừ kho — một statement

```sql
UPDATE stock SET qty = qty - 1 WHERE sku = 'A' AND qty >= 1;
-- 0 hàng: hết hàng, không lost update
```

### 15.2 RYW standby (PG 19)

```text
1. Primary: UPDATE …; COMMIT;
2. Primary: lsn ← pg_current_wal_insert_lsn()   -- hoặc flush LSN nếu cần bền
3. App gửi lsn sang connection standby
4. Standby: WAIT FOR LSN '<lsn>' WITH (MODE 'standby_replay', TIMEOUT '200ms', NO_THROW)
5. status = success → SELECT; else → SELECT trên primary
```

Không nhét bước 4 vào stored procedure.

### 15.3 Unique fail — hai abort model

```sql
-- SQL Server: không XACT_ABORT, “thử insert”
BEGIN TRAN;
INSERT INTO dbo.Users (Email) VALUES (N'a@x.com');  -- fail 2627 nếu trùng
-- @@TRANCOUNT vẫn 1 — NGUY HIỂM nếu COMMIT
ROLLBACK;
-- Đúng: MERGE / IF NOT EXISTS + UPDLOCK / catch + rollback

-- PostgreSQL
BEGIN;
INSERT INTO users (email) VALUES ('a@x.com')
ON CONFLICT (email) DO NOTHING
RETURNING id;
COMMIT;
```

### 15.4 FDW trong txn read-only (19)

```sql
START TRANSACTION READ ONLY;
SELECT * FROM ft;          -- OK
INSERT INTO ft VALUES (1); -- fail 19
COMMIT;

START TRANSACTION READ WRITE;   -- hoặc mặc định
INSERT INTO ft VALUES (1);
COMMIT;
```

### 15.5 SNAPSHOT 3960 vs PG 40001

Cùng ý “hàng đổi dưới snapshot”:

```sql
-- SQL Server
ALTER DATABASE Sales SET ALLOW_SNAPSHOT_ISOLATION ON;
SET TRANSACTION ISOLATION LEVEL SNAPSHOT;
BEGIN TRAN;
SELECT Qty FROM dbo.Stock WHERE Sku = N'A';
-- session khác COMMIT UPDATE cùng hàng
UPDATE dbo.Stock SET Qty = Qty - 1 WHERE Sku = N'A';  -- 3960
ROLLBACK;

-- PostgreSQL
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT qty FROM stock WHERE sku = 'A';
-- session khác COMMIT UPDATE
UPDATE stock SET qty = qty - 1 WHERE sku = 'A';       -- 40001
ROLLBACK;
```

Retry cả khối từ `SELECT`.

---

## 16. Best practices & checklist

- Transaction ngắn; không I/O mạng / prompt user bên trong.
- `XACT_ABORT ON` (SQL Server). Savepoint khi cần nuốt lỗi một bước (PostgreSQL).
- Chọn isolation theo invariant, không theo “nghe mạnh”: RC + atomic `UPDATE` đủ cho trừ kho; write skew mới cần SR/SSI hoặc constraint.
- RCSI khi reader block writer; đo `tempdb` hoặc ADR PVS. ADR rồi RCSI rồi mới optimized locking — [concurrency.md](concurrency.md).
- Không `NOLOCK` cho dữ liệu tài chính.
- Connection pool: luôn kết thúc txn trước khi trả connection.
- Long txn + logical replication / CES: log không truncate — monitor.
- Đọc replica: hiểu độ trễ; PG 19 dùng `WAIT FOR` `standby_replay` + timeout khi cần RYW. Không `WAITFOR DELAY`.
- PG 19: test `postgres_fdw` trong `READ ONLY`.
- Retry: 1205 / 40001 / 40P01 / 3960 — cả txn, jitter; phân biệt deadlock vs SSI.

---

## 17. Bẫy khi review

- `BEGIN` T-SQL bị hiểu là mở txn.
- `COMMIT` trong stored proc khi `@@TRANCOUNT > 1` — caller vẫn mở.
- `CATCH` rồi `COMMIT` trong khi `XACT_STATE() = -1`.
- Port `REPEATABLE READ` từ SQL Server sang PostgreSQL (hoặc ngược) không review anomaly.
- `SELECT` rồi tính ở app rồi `UPDATE` không khóa / không `WHERE qty = @old`.
- Gọi `txid_current()` / `nextval` “cho vui” — tạo xid / side effect.
- `SET TRANSACTION` sau DML.
- Giữ cursor/`HOLD` qua commit mà vẫn giả định snapshot cũ.
- `WAIT FOR replay OF WAL LSN` — **không** phải cú pháp 19; dùng `WAIT FOR LSN … WITH (MODE …)`.
- `WAIT FOR` `standby_flush` rồi `SELECT` — chưa replay.
- `WAIT FOR` trong function.
- FDW upsert trong `BEGIN READ ONLY` sau nâng 19.
- RCSI = hết lost update / write skew.
- Optimized locking = đổi isolation.
- Catch unique SS rồi tiếp tục cùng txn (`XACT_ABORT OFF`) port sang PG không rollback.
- Retry chỉ `UPDATE` cuối sau SSI abort.

---

## 18. Version gates

| Mục | SQL Server | PostgreSQL |
|---|---|---|
| ADR (accelerated recovery) | 2019+; **tempdb ADR** = **2025** | — (WAL + VM) |
| RCSI / SI | Lâu; RCSI phổ biến OLTP | RR ≈ SI từ rất sớm |
| Optimized locking | **2025** (on-prem off mặc định; cần ADR+RCSI) | — |
| `WAIT FOR LSN` + MODE/TIMEOUT/NO_THROW | — (`WAITFOR` = sleep) | **19** |
| SSI | — | 9.1+ |
| `COMMIT AND CHAIN` | — | 10+ |
| FDW thừa READ ONLY / DEFERRABLE | — | **19** |
| Deadlock / serialize retry | **1205** / **3960** | **40P01** / **40001** |

Lock mode, `SKIP LOCKED`, deadlock graph, tempdb 1138: [concurrency.md](concurrency.md).
