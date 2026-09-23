# Hệ thống kiểu dữ liệu

> **Baseline:** SQL Server **2025** · PostgreSQL **19**.  
> SQL không có CTS/.NET: kiểu là **column type** + **cast rule** + **operator class**. Hai engine **không** map 1-1.

Khi nói “cột `id` là int”, bạn chưa đủ thông tin để port. Cần biết storage, miền giá trị, typmod (`varchar(20)`, `numeric(12,2)`), collation, operator nào hợp lệ (`=`, `&&`, `->`), và indexability. `int` SQL Server và `integer` PostgreSQL gần nhau; `datetime` vs `timestamptz`, `bit` vs `boolean`, `nvarchar` vs `text`, `json` 2025 vs `jsonb` thì **không**. File này giải thích ngữ nghĩa — map máy móc 1-1 là nguồn bug.

Literal gắn kiểu: [literals.md](literals.md). Toán tử theo kiểu: [operators.md](operators.md). JSON sâu: [json.md](json.md). Storage TOAST/LOB, vector AM: [internal.md](internal.md).

---

## Mục lục

- [1. Tổng quan \& triết lý](#1-tổng-quan--triết-lý)
- [2. Số](#2-số)
  - [2.1 Integer](#21-integer)
  - [2.2 Decimal / numeric](#22-decimal--numeric)
  - [2.3 Float, Inf, NaN](#23-float-inf-nan)
  - [2.4 Identity \& sequence](#24-identity--sequence)
  - [2.5 Overflow \& `PRODUCT()`](#25-overflow--product)
- [3. Chuỗi \& binary](#3-chuỗi--binary)
- [4. Ngày giờ](#4-ngày-giờ)
  - [4.1 Bảng kiểu](#41-bảng-kiểu)
  - [4.2 Đồng hồ trong transaction](#42-đồng-hồ-trong-transaction)
  - [4.3 `AT TIME ZONE`](#43-at-time-zone)
  - [4.4 `CURRENT_DATE` vs `GETDATE`](#44-current_date-vs-getdate)
- [5. Boolean \& bit](#5-boolean--bit)
- [6. UUID / uniqueidentifier](#6-uuid--uniqueidentifier)
- [7. JSON](#7-json)
- [8. XML](#8-xml)
- [9. Array, range, composite (PostgreSQL)](#9-array-range-composite-postgresql)
- [10. Vector \& AI generate](#10-vector--ai-generate)
- [11. Spatial / hierarchy / sql_variant](#11-spatial--hierarchy--sql_variant)
- [12. NULL, domain, enum](#12-null-domain-enum)
- [13. Cast \& type precedence](#13-cast--type-precedence)
- [14. LOB / TOAST](#14-lob--toast)
- [15. Hai session — ví dụ làm việc](#15-hai-session--ví-dụ-làm-việc)
- [16. Best practices \& checklist](#16-best-practices--checklist)
- [17. Bẫy khi review](#17-bẫy-khi-review)
- [18. Version gates](#18-version-gates)
- [Phụ lục A. `PRODUCT` — kiểu vào / ra](#phụ-lục-a-product--kiểu-vào--ra)
- [Phụ lục B. JSON on-prem vs Azure](#phụ-lục-b-json-on-prem-vs-azure--cùng-chữ-json)
- [Phụ lục C. Half-precision vector](#phụ-lục-c-half-precision-vector--dung-lượng)

---

## 1. Tổng quan & triết lý

SQL Server: kiểu hệ thống cố định + alias (`sysname` = `nvarchar(128)`). User-defined: alias type (không CHECK), CLR type, table type. Catalog: `sys.types`.

PostgreSQL: **mọi thứ** là type trong `pg_type` — built-in, domain, enum, composite, range, multirange, array (`int4[]` là type riêng). Operator/function overload theo type; thất bại → `operator is not unique`.

Khi port một cột, hỏi:

1. Storage (cố định / varlena / LOB / TOAST).
2. Precision/scale và overflow.
3. NULL vs sentinel (`0`, `''`, `'1900-01-01'`).
4. So sánh / collation / NaN.
5. Index (btree, gin, columnstore, vector).

**Ghi chú:** `vector` SQL Server **2025** và `vector` pgvector **cùng tên, khác ship**: native vs extension, distance hàm vs operator `<->`, ANN index **PREVIEW** vs IVFFlat/HNSW. `json` 2025 on-prem nhiều phần **PREVIEW**; `jsonb` PG GA lâu.

---

## 2. Số

| Nhóm | SQL Server | PostgreSQL | Ghi chú |
|---|---|---|---|
| 8-bit | `tinyint` (0–255, unsigned) | — | PG: `smallint` hoặc domain `CHECK` |
| 16-bit | `smallint` | `smallint` / `int2` | Có dấu cả hai |
| 32-bit | `int` | `integer` / `int4` | |
| 64-bit | `bigint` | `bigint` / `int8` | |
| Tự tăng | `IDENTITY` / `SEQUENCE` | `GENERATED … AS IDENTITY` / `serial` (legacy) | Ưu tiên identity |
| Thập phân | `decimal`/`numeric`(p,s) | `numeric`(p,s) | Chính xác; chậm hơn float |
| Tiền | `money` / `smallmoney` | `money` | **Không khuyến nghị** — `numeric` |
| Float | `real`, `float(n)` | `real`, `double precision` | IEEE; `NaN`/`Infinity` **chỉ PG đầy đủ** |
| Bit-string | `bit` (boolean-ish 0/1) | `bit(n)` / `varbit` | PG `bit(n)` ≠ boolean |

### 2.1 Integer

```sql
-- SQL Server: tinyint không chứa số âm
DECLARE @t tinyint = 0;
-- SET @t = -1;                      -- overflow

-- PostgreSQL: không có unsigned 8-bit
SELECT (-1)::smallint;               -- OK
```

Chia nguyên cắt về 0 trên **cả hai** (`7/2 = 3`). Ép một toán hạng sang numeric/float khi cần phần thập phân — [operators.md](operators.md).

Hai session — overflow:

```text
T1 (SS): INSERT dbo.T (Qty) VALUES (2147483647);
         UPDATE dbo.T SET Qty = Qty + 1;     -- Arithmetic overflow, rollback statement (XACT_ABORT?)
T2 (PG): INSERT INTO t (qty) VALUES (2147483647);
         UPDATE t SET qty = qty + 1;         -- integer out of range
```

Cả hai **không wrap** kiểu C. `tinyint` SQL Server + port `smallint` PG: miền âm mở ra — CHECK `(qty >= 0)` nếu nghiệp vụ unsigned.

### 2.2 Decimal / numeric

`numeric(p,s)` / `decimal(p,s)`: `p` tổng chữ số, `s` sau dấu phẩy. SQL Server max precision 38. PostgreSQL `numeric` không (p) practically unlimited (chậm); `numeric(p,s)` giới hạn như khai báo.

```sql
-- Cả hai: tiền tệ
total numeric(19,4) NOT NULL

-- PostgreSQL: chia numeric giữ precision (không thành float)
SELECT pg_typeof(1.0 / 2);           -- numeric

-- SQL Server
SELECT SQL_VARIANT_PROPERTY(1.0 / 2, 'BaseType');  -- numeric
```

**Ghi chú:** `money` SQL Server (4 decimal, rounding ngân hàng kỳ lạ, overflow kiểu riêng) và `money` PostgreSQL (scale 2, **không** portable, bị ghét trên docs) — đừng dùng cột mới. Port `money` → `numeric(19,4)` có chủ đích.

Chia `numeric` vs `float` đổi báo cáo tài chính. Literal `1.23e0` là float — [literals.md](literals.md).

### 2.3 Float, Inf, NaN

```sql
-- PostgreSQL
SELECT 'Infinity'::float8, '-Infinity'::float8, 'NaN'::float8;
SELECT 'NaN'::numeric;
-- NaN = NaN là TRUE với numeric PG (SQL) — khác IEEE float (NaN = NaN → false)

SELECT 'NaN'::float8 = 'NaN'::float8;     -- false
SELECT 'NaN'::numeric = 'NaN'::numeric;   -- true
SELECT 'NaN'::numeric IS NOT DISTINCT FROM 'NaN'::numeric; -- true
```

SQL Server `real`/`float` không có literal `NaN`/`Infinity` kiểu PG; overflow integer → lỗi; một số phép float có thể ra Inf tùy phiên bản/expression — **đừng** thiết kế nghiệp vụ dựa vào Inf.

Sắp xếp: PG `NaN` numeric lớn hơn mọi số (đi cuối `ORDER BY ASC`). Unique index: hai `NaN` numeric **đụng** nhau.

**Ghi chú:** Vector SQL Server lưu float32 (hoặc half) — NaN trong embedding là bug model, không “SQL NaN”. Đừng unique-index cột `vector`.

### 2.4 Identity & sequence

```sql
-- SQL Server
CREATE TABLE dbo.Orders (
    Id int IDENTITY(1,1) NOT NULL PRIMARY KEY,
    …
);
SET IDENTITY_INSERT dbo.Orders ON;       -- session, một bảng tại một thời điểm

CREATE SEQUENCE dbo.OrderSeq AS bigint START WITH 1 INCREMENT BY 1;
SELECT NEXT VALUE FOR dbo.OrderSeq;

-- PostgreSQL
CREATE TABLE orders (
    id int GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    …
);
-- GENERATED ALWAYS: INSERT phải OVERRIDING SYSTEM VALUE để ép id
INSERT INTO orders (id, …) OVERRIDING SYSTEM VALUE VALUES (100, …);

CREATE SEQUENCE order_seq;
SELECT nextval('order_seq');
```

`serial` / `bigserial` = `integer`/`bigint` + sequence ẩn + default. Legacy: quyền sequence dễ lệch khi dump/restore. Cột mới: `GENERATED … AS IDENTITY`.

**Ghi chú:** Identity **có lỗ** sau `ROLLBACK` (cả hai): số đã phát không hoàn. Đừng dùng identity làm số hóa đơn liên tục. `CYCLE` / overflow sequence → lỗi hoặc quay vòng — cấu hình tường minh.

PG **19**: logical replication đồng bộ **sequence** (`ALL SEQUENCES`, `REFRESH SEQUENCES`) — failover identity. Trước 19: `setval` tay. Không đổi kiểu cột; đổi vận hành replica — [internal.md](internal.md), [ddl.md](ddl.md).

Hai session — lỗ identity:

```text
T1: INSERT → id = 5; ROLLBACK;
T2: INSERT → id = 6 (không phải 5)
-- Hóa đơn “liên tục” phải bảng counter + khóa, không IDENTITY.
```

### 2.5 Overflow & `PRODUCT()`

Integer overflow: **cả hai ném lỗi** (`Arithmetic overflow` / `integer out of range`). Không wrap kiểu C.

```sql
-- SQL Server 2025: DATEADD.number nhận bigint (trước: int — overflow dễ)
SELECT DATEADD(second, CAST(1 AS bigint) * 86400, SYSUTCDATETIME());

-- SQL Server 2025: PRODUCT() — aggregate nhân; overflow/numeric theo kiểu đầu vào
SELECT PRODUCT(factor) FROM dbo.Rates;

-- PostgreSQL: không có PRODUCT(); dùng exp(sum(ln())) cẩn thận dấu/zero/âm
SELECT exp(sum(ln(factor))) FROM rates WHERE factor > 0;
```

**Ghi chú kiểu `PRODUCT`:**

- Không phải kiểu cột. Aggregate, giống `SUM`/`AVG` — bỏ NULL, mọi hàng NULL → `NULL`.
- Kiểu ra theo kiểu vào: `int` nhân tràn → lỗi; `numeric` theo precision. Đừng `PRODUCT` trên `float` cho lãi suất kép rồi so tiền.
- Zero trong nhóm → 0. Âm: dấu theo số lượng âm (như nhân tay). PG `ln()` **không** nhận ≤ 0 — filter `factor > 0` đổi nghiệp vụ (bỏ hàng).
- Window `PRODUCT(…) OVER (…)`: nếu engine hỗ trợ aggregate window chuẩn — SQL Server aggregate thường vào `OVER`; đo trên 2025, không bịa `PRODUCT` FILTER. PG: không hàm này.

`DATEADD` bigint **2025**: khoảng giây lớn không còn overflow `int`. PG: `+ interval '1 second' * n` với `n` bigint/`numeric`.

---

## 3. Chuỗi & binary

| | SQL Server | PostgreSQL |
|---|---|---|
| ASCII/DBCS | `char(n)`, `varchar(n)`, `varchar(max)` | — (mọi text theo encoding DB, thường UTF8) |
| Unicode | `nchar`, `nvarchar`, `nvarchar(max)` | `char`, `varchar`, `text` |
| Không giới hạn | `varchar(max)` / `nvarchar(max)` (~2 GB) | `text` (legacy) / `varchar` không `(n)` |
| Binary | `binary(n)`, `varbinary(n)`, `varbinary(max)` | `bytea` |
| Deprecated | `text`/`ntext`/`image` | `bpchar` ít dùng tay |

```sql
-- Độ dài
-- SQL Server: LEN bỏ trailing space varchar; DATALENGTH tính byte
SELECT LEN(N'a '), DATALENGTH(N'a ');     -- 1 vs 4 (nvarchar = 2 byte/char BMP)

-- PostgreSQL: char_length / length = ký tự; octet_length = byte
SELECT length('a '), octet_length('á');   -- 2 ; 2 (UTF8)

-- SQL Server 2025: SUBSTRING(expr, start) — length optional (ANSI)
SELECT SUBSTRING(N'abcdef', 3);           -- N'cdef'

-- PostgreSQL
SELECT substring('abcdef' FROM 3);        -- 'cdef'
SELECT convert_from('\xDEADBEEF'::bytea, 'UTF8'); -- lỗi nếu không phải UTF-8 hợp lệ
```

`varchar(n)` SQL Server: `n` là **ký tự** với `varchar`; với `nvarchar` là độ dài UTF-16 (đơn vị 16-bit). Supplementary (emoji) = 2 đơn vị nếu collation **không** SC — cắt giữa surrogate.

PostgreSQL `varchar(n)`: `n` là **ký tự**, không phải byte. `'é'` đếm 1 dù 2 byte UTF-8.

**Ghi chú:**

- `char(n)` pad space: so sánh SQL Server thường bỏ trailing space (`ANSI_PADDING`); PG `bpchar` cũng đặc biệt. Đừng PK `char`.
- `varchar(max)` vs `varchar(n)`: index key SQL Server không lấy cả max (cần computed/`INCLUDE`/full-text). PG `text` index btree được đến ~1/3 page (~2700 byte) — dài hơn TOAST/hash/GIN.
- Binary: SQL Server `0xDEAD` literal; PG `bytea` hex `'\xDEAD'::bytea` — [literals.md](literals.md).
- SQL Server 2025: `BASE64_ENCODE` / `BASE64_DECODE` — hàm, **không** kiểu/`0b` literal. PG: `encode`/`decode`; **19** thêm `base64url` / `base32hex`. Output `varchar`/`text`/`bytea` tùy hàm — neo kiểu tường minh.

---

## 4. Ngày giờ

**Hình dung offset.** `datetimeoffset` (SQL Server) nhớ “15:00 **+07**”. `timestamptz` (PostgreSQL) nhớ **instant UTC** rồi *hiện* theo `TimeZone` session — hai client khác múi giờ thấy chữ khác, cùng một khoảnh khắc. Không có chỗ “giữ +07 gốc” trên `timestamptz`. `timestamp` không `tz` là đồng hồ tường **không biết múi** — đừng cộng với `timestamptz` rồi đoán.

`timestamp` trên T-SQL **không** phải thời gian: đó là `rowversion` (số tăng khi hàng đổi). Map sang PG `timestamp` là bug cổ điển.

### 4.1 Bảng kiểu

| Kiểu | SQL Server | PostgreSQL |
|---|---|---|
| Chỉ ngày | `date` | `date` |
| Thời gian | `time(n)` | `time(n)` / `timetz` (**tránh**) |
| Ngày+giờ | `datetime2(n)` (khuyến nghị), `datetime` (legacy) | `timestamp` / `timestamptz` |
| Offset | `datetimeoffset(n)` — **giữ offset gốc** | `timestamptz` — lưu UTC, hiện theo `TimeZone`; **mất offset gốc** |
| Duration | — (tính bằng `DATEDIFF` / `DATEADD`) | `interval` |
| Hiện tại | `SYSDATETIME()`, `SYSUTCDATETIME()`, `CURRENT_DATE` (**2025**) | `now()`, `clock_timestamp()`, `CURRENT_DATE` |

```sql
-- SQL Server 2025
SELECT CURRENT_DATE;                     -- kiểu date, ngày theo server
SELECT SYSDATETIMEOFFSET();
SELECT CAST(SYSUTCDATETIME() AS datetime2(7));

-- PostgreSQL
SELECT now();                            -- timestamptz, **đầu transaction**
SELECT clock_timestamp();                -- tường, đổi trong txn
SET TimeZone = 'Asia/Ho_Chi_Minh';
SELECT now();                            -- cùng instant, display khác
```

**Ghi chú:** SQL Server `datetime` làm tròn **3.33 ms** (increment 1/300 s) và không nhận năm trước 1753. Cột mới: `datetime2(n)` hoặc `datetimeoffset(n)`. `timestamp` T-SQL là **`rowversion`**, không phải thời gian — đừng map sang `timestamp` PG.

### 4.2 Đồng hồ trong transaction

Đây là lệch ngữ nghĩa cổ điển.

```text
-- PostgreSQL (một txn)
T0: BEGIN; SELECT now();                 -- 10:00:00.000
    … chờ 5 giây …
    SELECT now();                        -- vẫn 10:00:00.000
    SELECT clock_timestamp();            -- 10:00:05.xxx

-- SQL Server (một txn)
T0: BEGIN TRAN; SELECT SYSDATETIME();    -- 10:00:00
    … chờ 5 giây …
    SELECT SYSDATETIME();                -- 10:00:05  — không đóng băng theo txn
```

PostgreSQL: `now()` = `CURRENT_TIMESTAMP` = `transaction_timestamp()`. `statement_timestamp()` đổi theo statement. Default cột `DEFAULT now()` lấy thời điểm **bắt đầu txn** — insert hàng loạt trong một txn dài cùng timestamp.

SQL Server `DEFAULT SYSDATETIME()` lấy lúc **thực thi statement**.

`CURRENT_DATE` PG = ngày của `now()` (đầu txn, theo `TimeZone`). SQL Server 2025 `CURRENT_DATE` = kiểu `date` theo đồng hồ statement/server — **không** đóng băng txn kiểu PG. Đừng giả hai engine cùng “ngày txn”.

### 4.3 `AT TIME ZONE`

Cùng chữ, **khác toán**:

```sql
-- SQL Server: datetime2 AT TIME ZONE 'zone' = gắn zone, ra datetimeoffset
SELECT
    CAST('2026-09-13 12:00:00' AS datetime2(0))
        AT TIME ZONE 'SE Asia Standard Time';     -- +07:00
-- datetimeoffset AT TIME ZONE 'UTC' = đổi zone, giữ instant

-- PostgreSQL: timestamp AT TIME ZONE 'zone' = interpret as that zone → timestamptz
SELECT TIMESTAMP '2026-09-13 12:00:00' AT TIME ZONE 'Asia/Ho_Chi_Minh';
-- timestamptz AT TIME ZONE 'zone' = convert to timestamp **without** tz
SELECT TIMESTAMPTZ '2026-09-13 00:00:00+07' AT TIME ZONE 'UTC';
```

Tên zone: SQL Server dùng Windows (`SE Asia Standard Time`); PostgreSQL dùng IANA (`Asia/Ho_Chi_Minh`). Map tên không 1-1 (daylight).

### 4.4 `CURRENT_DATE` vs `GETDATE`

| Biểu thức | SQL Server 2025 | PostgreSQL |
|---|---|---|
| `CURRENT_DATE` | **2025**, kiểu `date` | lõi, kiểu `date`, neo txn |
| `GETDATE()` | `datetime` legacy (3.33 ms) | — |
| `SYSDATETIME()` | `datetime2(7)` | — |
| `SYSUTCDATETIME()` | `datetime2` UTC | `CURRENT_TIMESTAMP AT TIME ZONE 'UTC'` / `now() AT TIME ZONE 'UTC'` (cẩn thận kiểu) |
| `CURRENT_TIMESTAMP` | `datetime` (không `datetime2`) | `timestamptz` = `now()` |

**Ghi chú:** Cột tên `current_date` unquoted: `SELECT current_date` sau nâng 2025 **đổi nghĩa** thành hàm — [keywords.md](keywords.md). Default cột “ngày tạo”: SS `DEFAULT CAST(SYSUTCDATETIME() AS date)` hoặc `DEFAULT CURRENT_DATE`; PG `DEFAULT CURRENT_DATE` (ngày đầu txn).

Hai session — nửa đêm timezone:

```text
T1 (PG, TimeZone = Asia/Ho_Chi_Minh, txn mở 23:59):
    SELECT CURRENT_DATE;                 -- ngày D
    -- chờ sang 00:01
    SELECT CURRENT_DATE;                 -- vẫn D (đầu txn)
T2 (SS, cùng tường 00:01):
    SELECT CURRENT_DATE;                 -- ngày D+1
```

---

## 5. Boolean & bit

```sql
-- SQL Server: không có boolean. bit = 0 / 1 / NULL. Predicate là biểu thức riêng.
WHERE IsActive = 1
WHERE IsActive = 'true'    -- convert được trong vài ngữ cảnh — đừng dựa
-- IF (@bit) …             -- không: IF cần predicate; dùng IF (@bit = 1)

-- PostgreSQL
WHERE is_active             -- cột boolean là predicate
WHERE is_active IS TRUE     -- loại NULL
WHERE is_active = true
```

SQL Server `BIT` arithmetic promote lên `int` (`SUM(bit)` được). PostgreSQL `boolean` không cộng — `COUNT(*) FILTER (WHERE is_active)` hoặc `::int`.

`IS TRUE` / `IS FALSE` / `IS UNKNOWN`: PG đầy đủ. SQL Server không có trên `bit`.

**Ghi chú:** Driver ADO `bool` → `bit`. Npgsql `bool` → `boolean`. Port cột `bit` sang PG `boolean` rồi giữ `SUM(IsActive)` = lỗi kiểu.

---

## 6. UUID / uniqueidentifier

```sql
-- SQL Server
DECLARE @id uniqueidentifier = NEWID();          -- RFC 4122 v4
-- NEWSEQUENTIALID() chỉ trong DEFAULT constraint (không gọi ad-hoc)
CREATE TABLE dbo.Doc (
    Id uniqueidentifier NOT NULL
        CONSTRAINT DF_Doc_Id DEFAULT NEWSEQUENTIALID() PRIMARY KEY
);

-- PostgreSQL
SELECT gen_random_uuid();                        -- v4, core (PG 13+)
SELECT uuidv7();                                 -- PG 18+: time-ordered
```

Index btree + UUID v4 random → page split / fragmentation. Sequential (`NEWSEQUENTIALID`, `uuidv7`) tốt hơn cho PK btree. `NEWSEQUENTIALID` lộ MAC/thời gian (v1-ish) — cân nhắc privacy.

SQL Server `uniqueidentifier` so sánh **không** theo thứ tự byte RFC trên mọi API; sort binary khác string. PostgreSQL `uuid` type so sánh chuẩn.

**Ghi chú `uuidv7`:**

- PG **18+**, không phải 19-only. 19 không đổi chữ ký hàm.
- SQL Server **không** có `uuidv7()` built-in. Gần: `NEWSEQUENTIALID()` (không RFC 9562 v7) hoặc sinh phía app.
- PG 19: `bytea` ↔ `uuid` helper (encode path) — dùng khi pipeline binary, không thay `uuidv7()`.
- Clustered PK `uniqueidentifier` v4 trên SS = hotspot ngược (random); v7/sequential = tăng theo thời gian, tốt btree, kém “không đoán được” nếu dùng làm secret.

Hai session — PK random vs sequential:

```text
T1, T2 insert song song NEWID()/gen_random_uuid(): page split, latch
T1, T2 insert NEWSEQUENTIALID()/uuidv7(): append-ish, ít split hơn
```

---

## 7. JSON

SQL Server **2025** có kiểu **`json` native** (binary, tối đa ~2 GB/giá trị, UTF-8 nội bộ). Docs: **PREVIEW trên on-prem 2025**; GA Azure SQL / MI (policy 2025). Trước 2025: `nvarchar` + `JSON_VALUE` / `ISJSON`. Hàm cũ vẫn chạy trên `nvarchar` **và** `json`.

PostgreSQL: `json` (text, giữ khoảng trắng / thứ tự key / key trùng) và **`jsonb`** (binary, indexable). **`jsonb` là mặc định nên dùng.**

```sql
-- SQL Server 2025
CREATE TABLE dbo.Event (
    Id   int NOT NULL PRIMARY KEY,
    Doc  json NOT NULL
);
SELECT JSON_OBJECT('id': 1, 'name': N'Ada');
SELECT JSON_OBJECTAGG(k VALUE v) FROM pairs;     -- 2025; on-prem nhiều mục PREVIEW

-- PostgreSQL
CREATE TABLE event (
    id  int PRIMARY KEY,
    doc jsonb NOT NULL
);
SELECT jsonb_build_object('id', 1, 'name', 'Ada');
```

**PREVIEW on-prem (nhiều mục JSON 2025):**

- `CREATE JSON INDEX` — clustered PK bắt buộc; path `FOR` không chồng; tối ưu `JSON_VALUE` / `JSON_PATH_EXISTS` / `JSON_CONTAINS`.
- `JSON_CONTAINS`, wildcard path ANSI, `JSON_QUERY … WITH ARRAY WRAPPER`.
- `JSON_OBJECTAGG` / `JSON_ARRAYAGG` (`RETURNING JSON`).
- Method `modify` trên kiểu `json`.

```sql
CREATE JSON INDEX jix ON dbo.Doc (Payload) FOR ('$.status');  -- PREVIEW
```

JSON INDEX **không** trên heap-only (thiếu clustered PK). Path `$.a` recursive gồm `$.a.b`. Aggregate JSON GA trên Azure/Fabric DW trong khi on-prem preview — feature flag lệch môi trường.

Toán tử `->` / `->>` / `@>` là PostgreSQL. SQL Server dùng hàm `JSON_VALUE` / `JSON_QUERY` / `JSON_MODIFY` / `JSON_CONTAINS` — [json.md](json.md), [operators.md](operators.md).

`json_array()` 0 hàng: PG **19** trả `[]` (trước: `NULL`) — breaking khi upgrade. SQL Server `JSON_ARRAY()` constructor khác hàm aggregate `JSON_ARRAYAGG` — không nhầm `json_array()` PG.

**Ghi chú:** Đừng đổi `nvarchar` JSON sang `json` hàng loạt on-prem trước khi chấp nhận **PREVIEW** + clustered PK cho index. So sánh `=` trên `json`/`jsonb`/SS `json` **không** cùng (khoảng trắng, thứ tự key, binary canonical).

---

## 8. XML

```sql
-- SQL Server: kiểu xml, typed XML + XML SCHEMA COLLECTION, PRIMARY/SECONDARY XML index
SELECT T.X.value('(//id)[1]', 'int')
FROM dbo.Doc
CROSS APPLY Data.nodes('/root/item') AS T(X);

-- PostgreSQL: xml + xpath() / XMLTABLE; ít dùng hơn jsonb cho app mới
SELECT xpath('//id/text()', xml_col) FROM doc;
```

**Ghi chú:** XML index SQL Server đòi `QUOTED_IDENTIFIER ON` — [dialects.md](dialects.md). Đừng chọn XML chỉ vì “cần document”; JSON/`jsonb` đủ thì dùng JSON.

---

## 9. Array, range, composite (PostgreSQL)

SQL Server **không** có array type. Thay: table-valued parameter, JSON array, `STRING_SPLIT`, XML. Đừng giả lập array bằng `varchar` CSV.

```sql
-- PostgreSQL array
SELECT ARRAY[1,2,3];
SELECT tags[1], tags @> ARRAY['sql'] FROM posts;   -- 1-based index
UPDATE posts SET tags = tags || 'sql';

-- Range / multirange (application-time PG 18+ WITHOUT OVERLAPS; DML PG 19 FOR PORTION OF)
SELECT int4range(1, 10, '[)');                     -- 1 ≤ x < 10
SELECT datemultirange(daterange('2026-01-01', '2026-06-01'));

-- Composite
CREATE TYPE address AS (city text, zip text);
SELECT (ROW('HN', '10000')::address).city;
```

Range mặc định `[)` (đóng trái, mở phải). Overlap `&&` — [operators.md](operators.md). Temporal DML: [dml.md](dml.md). SQL Server temporal = system-versioned tables (cặp `DATETIME2` period), **không** phải `int4range`.

`vector(n)` **không** phải array `float[]`. Typmod số chiều cố định; operator distance khác `@>` array.

---

## 10. Vector & AI generate

```sql
-- SQL Server 2025 (GA: kiểu + distance; index ANN = PREVIEW)
CREATE TABLE dbo.Doc (
    Id        int NOT NULL PRIMARY KEY,
    Body      nvarchar(max) NOT NULL,
    Embedding vector(1536) NOT NULL          -- float32; có half-precision
);

SELECT VECTOR_DISTANCE('cosine', d.Embedding, @q) AS dist
FROM dbo.Doc AS d;
SELECT VECTOR_NORM(@q);
SELECT VECTOR_NORMALIZE(@q);
SELECT VECTORPROPERTY(@q, 'Dimensions');
```

| Mảnh | Trạng thái on-prem 2025 | Ghi chú |
|---|---|---|
| Kiểu `vector(n)` | **GA** | Binary storage; client thấy JSON array |
| Phần tử float32 (4 byte) | **GA** | Mặc định |
| Half-precision (2 byte) | **GA** (kiểu) | Giảm RAM/IO; đo recall — không đổi `VECTOR_DISTANCE` API |
| `VECTOR_DISTANCE` / `VECTOR_NORM` / `VECTOR_NORMALIZE` / `VECTORPROPERTY` | **GA** | Metric `'cosine'` / docs metric khác — đối chiếu Learn, không bịa tên metric |
| `CREATE EXTERNAL MODEL` / `ALTER` / `DROP` | GA surface | REST embedding, credential **tách** engine |
| `AI_GENERATE_EMBEDDINGS` / `AI_GENERATE_CHUNKS` | GA surface | Chunk + gọi model đã định nghĩa |
| `CREATE VECTOR INDEX` (DiskANN), `VECTOR_SEARCH` | **PREVIEW** | Cần `PREVIEW_FEATURES`; catalog `sys.vector_indexes` |
| Hybrid vector + full-text | GA ý | **Không** SQL/PGQ |

```sql
-- PREVIEW
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;
-- CREATE VECTOR INDEX … ON dbo.Doc (Embedding);
-- SELECT … FROM VECTOR_SEARCH(…)
```

```sql
-- PostgreSQL: không native; extension pgvector
CREATE EXTENSION vector;
CREATE TABLE doc (
    id int PRIMARY KEY,
    embedding vector(1536)
);
-- Operator <-> / <=> / <#> — [operators.md](operators.md)
-- Index IVFFlat / HNSW: extension, không PREVIEW_FEATURES
```

**Ghi chú:**

- SQL Server `vector` expose JSON array khi đọc client, lưu binary. Đừng `varchar` hóa embedding.
- Model/REST: credential store, không hard-code key trong proc. `sp_invoke_external_rest_endpoint` cùng họ rủi ro mạng từ engine — không phải kiểu cột.
- `VECTOR_SEARCH` / `CREATE VECTOR INDEX` = **PREVIEW**. Kiểu + distance dùng được không bật preview; ANN thì phải.
- Bật `PREVIEW_FEATURES` “cho vector” kéo CES/fuzzy trên **cùng** database — [dialects.md](dialects.md).
- pgvector operators (`<->`, `<=>`) không có trên SQL Server; đừng copy. Chiều `vector(1536)` phải khớp model; `VECTORPROPERTY(…, 'Dimensions')` vs typmod.
- Half-precision: cùng số chiều, khác dung lượng; mix float32/half trong một `VECTOR_DISTANCE` — kiểm docs (thường đòi cùng layout). Không bịa implicit cast.
- Hybrid search ≠ `GRAPH_TABLE` ([keywords.md](keywords.md), [select.md](select.md)).

Hai session — PREVIEW index:

```text
T1: PREVIEW_FEATURES = ON; CREATE VECTOR INDEX …
T2: cùng DB, query VECTOR_SEARCH — lab OK
    -- Production CU đổi API ANN: T2 fail; kiểu vector(n) GA vẫn đọc được
```

---

## 11. Spatial / hierarchy / sql_variant

| Kiểu | SQL Server | PostgreSQL |
|---|---|---|
| Geometry | `geometry`, `geography` (SRID) | `geometry` / `geography` (**PostGIS**, extension) |
| Hierarchy | `hierarchyid` | `ltree` (extension) / recursive CTE |
| Variant | `sql_variant` (**tránh**) | — |
| Row version | `rowversion` / `timestamp` (không phải thời gian) | `xmin` / `xmax` system column (MVCC) — [transactions.md](transactions.md), [internal.md](internal.md) |
| Alias | `sysname` | `name` (catalog, 63 byte) |

`sql_variant` mất collation/precision khi convert, cấm một số kiểu (`xml`, `geography`, `max`), khó index — đừng cột mới.

`rowversion` tự đổi mỗi update hàng; dùng cho optimistic concurrency, **không** làm thời gian tạo.

---

## 12. NULL, domain, enum

Cột `NULL` / `NOT NULL` là thuộc tính cột, không phải kiểu — trừ domain PG gắn `NOT NULL`.

```sql
-- PostgreSQL domain: kiểu + CHECK tái sử dụng
CREATE DOMAIN email AS text CHECK (VALUE ~ '^[^@]+@[^@]+$');

-- SQL Server: alias type không có CHECK; constraint trên bảng
CREATE TYPE dbo.Email FROM nvarchar(320);
-- CHECK (email LIKE '%_@_%.__%') trên từng bảng

-- PostgreSQL enum
CREATE TYPE order_status AS ENUM ('new', 'paid', 'shipped');
ALTER TYPE order_status ADD VALUE 'cancelled';
-- PG 12+: ADD VALUE được trong txn; **không dùng** giá trị mới trước COMMIT

-- SQL Server: không có enum; CHECK / lookup table / PK nhỏ
```

**Ghi chú:** Enum PG khó bỏ giá trị; rename/reorder hạn chế. Lookup table portable hơn khi nghiệp vụ đổi trạng thái. Unique + NULL: [dialects.md §6.2](dialects.md#62-unique--null), [constraints.md](constraints.md).

Domain trên `vector` / `json` — được về mặt type PG; SQL Server alias `FROM json` / `FROM vector(n)`: kiểm `sys.types`, đừng giả CLR. On-prem `json` **PREVIEW**: alias không làm GA.

---

## 13. Cast & type precedence

```sql
-- SQL Server: CAST / CONVERT / PARSE / TRY_*
SELECT CONVERT(date, '2026-09-13', 23);     -- style 23 = ISO yyyy-mm-dd
SELECT TRY_CAST('x' AS int);                -- NULL, không lỗi
SELECT PARSE('13/09/2026' AS date USING 'en-GB'); -- CLR culture — đắt, tránh hot path

-- PostgreSQL
SELECT '2026-09-13'::date;
SELECT CAST('x' AS int);                    -- lỗi (không có TRY_CAST lõi)
-- Validate trước, hoặc PL/pgSQL BEGIN … EXCEPTION WHEN invalid_text_representation
```

Precedence SQL Server (rút gọn, cao → thấp): user-defined → `sql_variant` → `xml` → `datetimeoffset` → `datetime2` → `datetime` → `date` → … → `float` → `real` → `decimal` → `money` → `int` → `bit` → `nvarchar` → `varchar` → `binary`.

Hệ quả: `'1' + 2` → int 3 (chuỗi convert số); `1 + N'2'` tương tự. `'a' + 2` → lỗi convert. Nối chuỗi: ép `CONVERT(varchar, n)` hoặc `CONCAT`.

PostgreSQL: chọn operator **best match** trong `pg_operator`; thất bại → `operator is not unique` / `cannot resolve`. Cast implicit **ít hơn** SQL Server — `'1' + 2` không thành 3 (không có `text + int`); `'1'::int + 2` hoặc `concat`.

```sql
-- PostgreSQL
SELECT pg_typeof(1 + 1.2);                  -- numeric
SELECT pg_typeof(1 + 1.2::float8);          -- double precision
```

`CAST(N'[0.1, 0.2]' AS vector(2))` (SS) vs `'[0.1, 0.2]'::vector` (pgvector): JSON-array text → binary. Sai số chiều → lỗi. `CAST(… AS json)` on-prem 2025: surface **PREVIEW** cho kiểu native.

PG 19 `error_on_null()` — hàm, không phải cast. Dùng khi cần fail NULL, không nhét mọi API vào cột.

---

## 14. LOB / TOAST

SQL Server: `varchar(max)` / `nvarchar(max)` / `varbinary(max)` / `xml` / `json` lưu in-row đến giới hạn rồi LOB (text/image page). `SELECT *` kéo LOB — đắt. Columnstore có LOB riêng; 2025 shrink CS cải thiện — [internal.md](internal.md).

PostgreSQL: giá trị lớn **TOAST** (nén + out-of-line). PG **19**: `default_toast_compression = lz4` (trước `pglz`). Cột ít đọc: `ALTER TABLE … ALTER COLUMN … SET STORAGE EXTERNAL`.

**Ghi chú:** Cập nhật 1 cột TOAST/LOB có thể rewrite cả giá trị. JSON document 10 MB update 1 key = I/O lớn — cân nhắc tách bảng. `vector(1536)` float32 ≈ 6 KB + header — gần/ trên ngưỡng TOAST tùy; half ≈ 3 KB. ANN index **PREVIEW** không thay TOAST policy.

---

## 15. Hai session — ví dụ làm việc

### 15.1 `now()` vs `SYSDATETIME` trong txn dài

Đã ở §4.2. Hệ quả ETL: PG `DEFAULT now()` mọi hàng batch một timestamp; SS mỗi statement một mốc. Audit “cùng txn cùng giờ” chỉ đúng PG.

### 15.2 `json_array()` rỗng sau nâng PG 19

```text
T1 (PG 18): SELECT json_array() FROM t WHERE false;     -- NULL (0 hàng)
T2 (PG 19): cùng query                                 -- []
Client: if (doc == null) “không phần tử” → vỡ; [] là array rỗng hợp lệ
```

SQL Server `JSON_ARRAYAGG` 0 hàng: đối chiếu Learn (thường `NULL` aggregate) — **không** copy breaking PG.

### 15.3 `PRODUCT` overflow

```text
T1: SELECT PRODUCT(rate) FROM dbo.Rates;     -- numeric/int theo cột
    -- rate int, nhiều hàng → overflow, statement abort
T2: CAST(rate AS numeric(19,6)) rồi PRODUCT  -- chậm hơn, không tràn int
```

PG T2: `exp(sum(ln(rate)))` với `rate = 0` → `ln` fail. Filter đổi tích.

### 15.4 Vector half vs float32

```text
T1: Embedding vector(1536) float32, VECTOR_DISTANCE cosine
T2: cột half-precision cùng 1536 — dung lượng ~½
    Mix hai layout trong một câu distance: kiểm docs; đừng giả implicit
```

### 15.5 UUID v7 vs v4 PK

```text
T1: INSERT uuidv7() / NEWSEQUENTIALID() clustered
T2: INSERT gen_random_uuid() / NEWID()
-- T2 split trang; T1 append. Privacy: sequential đoán được hơn v4.
```

---

## 16. Best practices & checklist

- Tiền: `numeric(p,s)`, không `money` / float.
- Thời điểm UTC: PG `timestamptz`; SQL Server `datetime2` + quy ước UTC **hoặc** `datetimeoffset` nếu cần giữ offset gốc.
- Chuỗi: PG `text`/`varchar`; SQL Server `nvarchar` trừ khi chắc code page. Tránh `ntext`/`text`/`image`.
- Boolean: PG `boolean`; SQL Server `bit` + so sánh `= 1`.
- JSON: PG `jsonb`; SQL Server 2025 `json` native — on-prem nhiều phần **PREVIEW**; không `nvarchar` mới nếu đã chấp nhận preview.
- PK phân tán: `uuidv7()` / `NEWSEQUENTIALID`, không v4 làm clustered key.
- Vector: kiểu + distance **GA** SQL 2025; ANN index / `VECTOR_SEARCH` **PREVIEW**. Half-precision đo recall. PG: `pgvector` — ghi rõ extension. `AI_GENERATE_*` + credential, không key trong proc.
- `PRODUCT`: neo `numeric`; nhớ NULL/zero/âm. PG không có hàm.
- `CURRENT_DATE` 2025 ≠ `GETDATE()`; PG neo txn.
- Enum: lookup table nếu port / đổi giá trị thường xuyên.
- `TRY_CAST` cho input bẩn (SQL Server); PG validate trước hoặc PL block.
- Đo overflow integer / `PRODUCT` / `numeric` scale trước production.
- `json_array()` client: `[]` vs `NULL` sau PG 19.

---

## 17. Bẫy khi review

- Map `datetime` → `timestamp` (PG) hoặc `timestamp` T-SQL → thời gian.
- Map `bit` → `boolean` rồi `SUM(bit)` trên PG.
- `AT TIME ZONE` copy nguyên văn giữa hai engine.
- `now()` mặc định cột PG trong txn dài — mọi hàng cùng timestamp.
- `varchar(n)` đếm byte vs ký tự vs UTF-16 unit (emoji).
- `NaN = NaN` numeric PG trong unique/join.
- `tinyint` âm; unsigned giả định trên PG.
- `serial` dump thiếu `OWNED BY` / grant sequence.
- `sql_variant` / `money` cột mới.
- `vector` **index** trên prod khi mới `PREVIEW_FEATURES`.
- `json` native on-prem như đã GA Azure; JSON INDEX trên heap.
- `json` text PG (giữ key trùng) vs `jsonb` vs SQL Server `json` binary — so sánh `=` khác nhau.
- Implicit `'1'+2` T-SQL sống sót khi port — PG lỗi lúc chạy.
- `CURRENT_DATE` cột vs hàm sau nâng 2025.
- `PRODUCT(float)` cho tiền; `exp(sum(ln()))` có zero/âm.
- `uuidv7` bịa trên T-SQL; `NEWID` làm clustered “cho nhanh”.
- Mix half/float32 embedding không đo.
- `AI_GENERATE_EMBEDDINGS` nhét API key trong thân proc.
- `json_array()` 0 hàng: client `IS NULL` sau PG 19.

---

## 18. Version gates

| Mục | SQL Server | PostgreSQL |
|---|---|---|
| Kiểu `json` native | **2025 PREVIEW** on-prem (Azure GA hơn) | `json`/`jsonb` lâu (`jsonb` 9.4+) |
| `JSON_OBJECTAGG` / `JSON_ARRAYAGG` | **2025** (on-prem nhiều **PREVIEW**) | `json_object_agg` lâu |
| `JSON INDEX` / `JSON_CONTAINS` | **2025 PREVIEW** | GIN `@>` |
| `vector(n)` + distance | **2025 GA** | pgvector (extension) |
| Half-precision vector | **2025** | pgvector typmod/storage — docs extension |
| `VECTOR_SEARCH` / vector index | **2025 PREVIEW** | pgvector IVFFlat/HNSW |
| `AI_GENERATE_EMBEDDINGS` / `AI_GENERATE_CHUNKS` / `EXTERNAL MODEL` | **2025** | app-side / extension |
| `CURRENT_DATE` | **2025** | lõi |
| `SUBSTRING` length optional | **2025** | lõi (`substring FROM`) |
| `DATEADD` bigint | **2025** | `+ interval` |
| `PRODUCT()` | **2025** | — |
| `BASE64_ENCODE` / `DECODE` | **2025** | `encode`/`decode`; **19** base64url/base32hex |
| `uuidv7()` | — (`NEWSEQUENTIALID`) | **18+** |
| `gen_random_uuid()` core | `NEWID()` | **13+** |
| Identity ANSI | `IDENTITY` lâu | `GENERATED … IDENTITY` **10+** |
| Logical sequence sync | — | **19** |
| `UNIQUE NULLS NOT DISTINCT` | — | **15+** |
| TOAST default lz4 | — | **19** (`default_toast_compression`) |
| `json_array()` rỗng → `[]` | — | **19** (trước: `NULL`) |

Map nhanh ý định: PK số → `int IDENTITY` / `int GENERATED BY DEFAULT AS IDENTITY`. Tiền → `numeric(19,4)`. Unicode → `nvarchar` / `text`. Binary → `varbinary(max)` / `bytea`. Instant UTC → `datetime2`+quy ước / `timestamptz`. Boolean → `bit` / `boolean`. Embedding → `vector(n)` / pgvector — ANN **PREVIEW** phía SS.

---

## Phụ lục A. `PRODUCT` — kiểu vào / ra

`PRODUCT` không có trên PostgreSQL. Trên SQL Server **2025** nó là aggregate, không kiểu cột.

```sql
-- SQL Server
SELECT PRODUCT(CAST(factor AS numeric(19,6))) AS p
FROM dbo.Rates
WHERE factor IS NOT NULL;
```

| Đầu vào | Rủi ro |
|---|---|
| `int` / `bigint` | Overflow statement abort — ép `numeric` trước khi nhân dồn |
| `numeric(p,s)` | Precision tích có thể vượt `p` — khai báo rộng hơn cột nguồn |
| `float`/`real` | Sai số kép; Inf không phải hợp đồng nghiệp vụ |
| Có 0 | Tích = 0 (đúng nhân); PG `ln(0)` fail nếu mô phỏng `exp(sum(ln()))` |
| Có âm | Dấu theo số lượng âm; `ln` âm không thực — filter `> 0` **đổi** tích |
| NULL | Bỏ như `SUM`; mọi hàng NULL → `NULL` (không phải 1) |

Window: nếu dùng `PRODUCT(x) OVER (ORDER BY d)` — đo trên 2025; không `FILTER`/`IGNORE NULLS` giả ANSI. PG: CTE nhân dồn `exp(sum(ln(x)) OVER (…))` cùng hạn chế dấu/zero.

`DATEADD(…, bigint, …)` **2025** là hàm datetime, không aggregate — đừng nhóm với `PRODUCT` trong review “hàm mới 2025” rồi quên overflow từng loại.

---

## Phụ lục B. JSON on-prem vs Azure — cùng chữ `json`

| Mảnh | On-prem 2025 | Azure SQL / MI (policy 2025) |
|---|---|---|
| Kiểu `json` binary | **PREVIEW** (docs) | GA hơn on-prem |
| `JSON_VALUE` / `OPENJSON` / `FOR JSON` trên `nvarchar` | GA (lâu) | GA |
| `CREATE JSON INDEX` | **PREVIEW** | đối chiếu portal — đừng copy flag |
| `JSON_OBJECTAGG` / `JSON_ARRAYAGG` | **PREVIEW** nhiều phần | thường GA cloud sớm hơn |
| `JSON_CONTAINS` | **PREVIEW** | đối chiếu Learn |

Hai session — staging Azure, prod on-prem:

```text
T1 (Azure): CREATE TABLE … (Doc json); CREATE JSON INDEX …
T2 (on-prem, PREVIEW_FEATURES off): CREATE TABLE … (Doc json);  -- kiểu có thể fail / preview
    CREATE JSON INDEX …                                         -- fail
```

Rollback: `nvarchar(max)` + `ISJSON` dễ hơn `json` + index clustered PK. Đổi kiểu hàng loạt = rewrite LOB — [internal.md](internal.md).

---

## Phụ lục C. Half-precision vector — dung lượng

`vector(1536)` float32 ≈ 1536 × 4 ≈ 6 KB/hàng (chưa header/alignment). Half ≈ 3 KB. 10 triệu hàng: ~60 GB vs ~30 GB raw, chưa ANN index **PREVIEW**.

```sql
SELECT VECTORPROPERTY(@q, 'Dimensions');   -- 1536 — không nói float vs half
```

Hai session — model 1536 float vs cột half:

```text
T1: AI_GENERATE_EMBEDDINGS → float32 1536
T2: INSERT cột half-precision — kiểm implicit; đo cosine drift
-- Không giả CAST im lặng như numeric→int. Credential model: không trong literal proc.
```

pgvector: typmod chiều; storage half tùy version extension — đọc docs extension, không bịa tên type SQL Server trên PG.
