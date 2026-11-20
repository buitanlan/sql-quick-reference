# Routine (procedure, function, trigger)

> **Baseline:** SQL Server **2025** (T-SQL) · PostgreSQL **19** (GA 19/11/2026) (SQL / PL/pgSQL).<br>
> Routine là mã *trong engine*: biên dịch, quyền, transaction, search_path. Không phải API HTTP mặc định — trừ khi bạn cố ý gọi REST (§9) hoặc model ngoài (§10).

Procedure và function **không** đổi tên được khi port. T-SQL function cấm side-effect mạnh; PL/pgSQL `VOLATILE` function ghi bảng được nhưng khó test. Trigger hai dialect đều **set-based** (SS `inserted`/`deleted` nhiều hàng; PG `FOR EACH ROW` vẫn phải nghĩ burst). Dynamic SQL sai quoting = injection. File này là hợp đồng review, không phải gen CRUD.

Hàm built-in: [functions.md](functions.md). Txn trong routine: [transactions.md](transactions.md). CTE / `MAXRECURSION` trong TVF: [cte-subqueries.md](cte-subqueries.md).

---

## Mục lục

- [1. Tổng quan & triết lý](#1-tổng-quan--triết-lý)
- [2. Procedure vs function](#2-procedure-vs-function)
- [3. T-SQL vs PL/pgSQL](#3-t-sql-vs-plpgsql)
- [4. Stored procedure](#4-stored-procedure)
- [5. Function: scalar, inline TVF, MSTVF](#5-function-scalar-inline-tvf-mstvf)
  - [5.1 Scalar](#51-scalar)
  - [5.2 Inline TVF vs MSTVF](#52-inline-tvf-vs-mstvf)
- [6. Trigger set-based](#6-trigger-set-based)
- [7. Dynamic SQL & quoting](#7-dynamic-sql--quoting)
- [8. Optimized `sp_executesql` (compilation storm)](#8-optimized-sp_executesql-compilation-storm)
- [9. `sp_invoke_external_rest_endpoint`](#9-sp_invoke_external_rest_endpoint)
- [10. `CREATE EXTERNAL MODEL`](#10-create-external-model)
- [11. Quyền: `SECURITY DEFINER` & `search_path`](#11-quyền-security-definer--search_path)
- [12. Worked examples](#12-worked-examples)
- [13. Lỗi: `TRY`/`CATCH` vs `EXCEPTION`](#13-lỗi-trycatch-vs-exception)
- [14. `EXEC(@sql)` vs `sp_executesql` vs `PREPARE`](#14-execsql-vs-sp_executesql-vs-prepare)
- [15. Best practices & checklist](#15-best-practices--checklist)
- [16. Bẫy khi review](#16-bẫy-khi-review)
- [17. Version gates](#17-version-gates)
- [Phụ lục A. `INSTEAD OF` vs `BEFORE`](#phụ-lục-a-instead-of-vs-before)
- [Nguồn chính thức](#nguồn-chính-thức)

---

## 1. Tổng quan & triết lý

Routine chạy với **session** caller (mặc định), plan cache, và lock của txn đang mở. Giữ logic nghiệp vụ trong engine khi: một round-trip, ràng buộc sát dữ liệu, không lộ SQL cho client. Đưa ra app khi: orchestration, HTTP, retry, fan-out.

Ba ranh giới dễ vỡ:

- **Giao dịch:** PG function *không* `COMMIT`; PG procedure `COMMIT` chỉ khi `CALL` ngoài khối `BEGIN`. T-SQL proc tự `BEGIN TRAN` lồng `@@TRANCOUNT` — [transactions.md](transactions.md).
- **Optimizer:** inline TVF / SQL-language function có thể *mở* vào query ngoài; MSTVF / PL/pgSQL / scalar UDF (trước FROID) là bức tường cardinality.
- **Tên object:** `search_path` / default schema. `SECURITY DEFINER` + path viết được = hijack.

HTTP từ engine (`sp_invoke_external_rest_endpoint`, `AI_GENERATE_EMBEDDINGS`) kéo timeout vào lock txn — §9–10.

---

## 2. Procedure vs function

| | Procedure | Function |
|---|---|---|
| Gọi | `EXEC` / `EXECUTE` (SS); `CALL` (PG) | Biểu thức, `SELECT`, `FROM` (TVF/SRF) |
| Giá trị trả | SS: result set + `OUTPUT` + `RETURN int`; PG: OUT param, không `RETURNS` | Scalar / table / `SETOF` |
| Side effect | Được | SS: hạn chế (không DML tùy tiện trong scalar/TVF thường); PG: được nếu `VOLATILE` |
| `COMMIT`/`ROLLBACK` | PG: được (điều kiện §4); SS: được, nuốt `@@TRANCOUNT` | PG: **cấm**; SS: không dùng như proc |
| Trong SQL | SS không `SELECT dbo.Proc()` | `SELECT fn(x)`, `FROM fn(x)` |

PostgreSQL: result set “bảng” thường là **`RETURNS TABLE` / `SETOF`** function, không phải procedure. Procedure = thủ tục, `CALL`, OUT param.

SQL Server: proc trả 0..n result set (client ADS/JDBC “next result”). Function TVF dùng trong `FROM`/`APPLY`.

---

## 3. T-SQL vs PL/pgSQL

```sql
-- T-SQL: batch, biến @, SET/SELECT gán, BEGIN/END không phải txn
CREATE OR ALTER PROCEDURE dbo.P @id int
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @n int;
    SELECT @n = COUNT(*) FROM dbo.Orders WHERE CustomerId = @id;
    IF @n = 0
        THROW 50001, N'not found', 1;
END;
```

```sql
-- PL/pgSQL: DECLARE, BEGIN/EXCEPTION/END, := , RETURN
CREATE OR REPLACE PROCEDURE p(id int)
LANGUAGE plpgsql
AS $$
DECLARE
    n int;
BEGIN
    SELECT COUNT(*) INTO n FROM orders WHERE customer_id = id;
    IF n = 0 THEN
        RAISE EXCEPTION 'not found' USING ERRCODE = 'P0002';
    END IF;
END;
$$;
```

| | T-SQL | PL/pgSQL |
|---|---|---|
| Biến | `@n`, gán `SET` / `SELECT @n =` | `n`, `:=` / `INTO` |
| Lỗi statement | Mặc định *không* abort txn (`XACT_ABORT OFF`) | Abort txn; `EXCEPTION` = savepoint ẩn |
| `THROW` / `RAISERROR` | `THROW` (sau 2012) | `RAISE EXCEPTION` / `NOTICE` |
| Cursor | Có; tránh | `FOR r IN SELECT` thường đủ |
| `GO` | Tách batch client | Không có |
| `CREATE OR ALTER` | Proc/func/trigger (tùy object) | `CREATE OR REPLACE` |

**Gán biến từ `SELECT` (SS vs PG):**
- SQL Server `SELECT @n = col FROM t`: 0 hàng → **giữ nguyên giá trị cũ** của `@n` (bẫy cổ điển trong vòng lặp); >1 hàng → im lặng lấy hàng cuối được xử lý (không xác định nếu thiếu `ORDER BY`).
- SQL Server `SET @n = (SELECT col FROM t)`: 0 hàng → gán **`NULL`**; >1 hàng → **ném lỗi `Msg 512`** (subquery returned more than 1 value).
- PL/pgSQL `SELECT col INTO n`: 0 hàng → gán `NULL`; >1 hàng → lấy hàng đầu. Dùng **`INTO STRICT`** khi cần bắt buộc đúng 1 hàng (0 hàng → `NO_DATA_FOUND`, >1 hàng → `TOO_MANY_ROWS`). [PL/pgSQL statements](https://www.postgresql.org/docs/19/plpgsql-statements.html).

**Ghi chú:** Port `BEGIN` T-SQL (khối lệnh) sang PG `BEGIN` (txn hoặc block PL) — [transactions.md](transactions.md) §2.

---

## 4. Stored procedure

```sql
-- SQL Server
CREATE OR ALTER PROCEDURE dbo.GetOrders
    @customer_id int,
    @min_total   decimal(12,2) = 0
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, Total
    FROM dbo.Orders
    WHERE CustomerId = @customer_id
      AND Total >= @min_total;
END;
GO
EXEC dbo.GetOrders @customer_id = 1, @min_total = 10;
```

```sql
-- PostgreSQL: procedure không SELECT ra client như T-SQL
CREATE OR REPLACE PROCEDURE get_orders(p_customer int, p_min numeric DEFAULT 0)
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE NOTICE 'customer % min %', p_customer, p_min;
    -- COMMIT chỉ khi CALL không nằm trong BEGIN … COMMIT sẵn
END;
$$;
CALL get_orders(1, 10);

-- Result set: function
CREATE OR REPLACE FUNCTION get_orders(p_customer int, p_min numeric DEFAULT 0)
RETURNS TABLE (id int, total numeric)
LANGUAGE sql
STABLE
AS $$
    SELECT id, total FROM orders
    WHERE customer_id = p_customer AND total >= p_min
$$;
SELECT * FROM get_orders(1, 10);
```

PG: `CALL` trong `BEGIN` tường minh → procedure **không** `COMMIT` giữa chừng (lỗi). `SECURITY DEFINER` procedure **không** được transaction control. `SET search_path` trên procedure cũng **cấm** `COMMIT` trong body (docs 19: `SET` clause và definer đều chặn txn control).

SS: `EXEC proc` trong txn caller tăng `@@TRANCOUNT` nếu proc `BEGIN TRAN`. `COMMIT` trong proc khi count > 1 chỉ giảm 1 — caller vẫn mở.

Parameter sniffing: plan theo lần chạy đầu. SS: `OPTIMIZE FOR`, `RECOMPILE`, OPPO (**2025**, optional parameter). PG: `plan_cache_mode`, generic vs custom; PG 19 `pg_plan_advice` / `pg_stash_advice`.

**Tham số `OUTPUT` & TVP (SQL Server):**
- Tham số `OUTPUT` phải ghi từ khóa `OUTPUT` ở **cả định nghĩa lẫn lời gọi** (`EXEC dbo.P @id = 1, @total = @out OUTPUT;` — quên `OUTPUT` lúc gọi thì `@out` không nhận giá trị mà không báo lỗi).
- **Table-Valued Parameter (TVP):** tạo `CREATE TYPE dbo.IntList AS TABLE (Id int PRIMARY KEY);` và truyền vào proc/func với từ khóa bắt buộc **`READONLY`** (`@ids dbo.IntList READONLY`) — an toàn và sạch hơn nối chuỗi `IN (...)` dynamic; bên PG dùng mảng (`int[]` + `= ANY($1)`).

---

## 5. Function: scalar, inline TVF, MSTVF

### 5.1 Scalar

```sql
-- SQL Server (2019+: kiểm soát inlining bằng WITH INLINE = ON | OFF)
CREATE OR ALTER FUNCTION dbo.Tax(@n decimal(12,2))
RETURNS decimal(12,2)
WITH SCHEMABINDING, INLINE = ON
AS
BEGIN
    RETURN @n * 0.10;
END;

-- PostgreSQL 14+: SQL-standard body (parse & track dependency lúc CREATE)
CREATE OR REPLACE FUNCTION tax(n numeric)
RETURNS numeric
LANGUAGE sql
IMMUTABLE STRICT PARALLEL SAFE
BEGIN ATOMIC
    SELECT n * 0.10;
END;
```

**SQL Server Scalar UDF Inlining (FROID, 2019+):** tự động chuyển scalar UDF thành biểu thức/subquery nội tuyến thay vì chạy từng hàng (RBAR). Kiểm tra hàm có đủ điều kiện không qua **`sys.sql_modules.is_inlineable`** (`1`/`0`), bật/tắt từng hàm bằng `WITH INLINE = ON | OFF`, hoặc cấp DB qua `ALTER DATABASE SCOPED CONFIGURATION SET TSQL_SCALAR_UDF_INLINING = OFF | ON;`. Các yếu tố làm **mất inline**: gọi hàm thời gian/nondeterministic (`GETDATE`, `NEWID`), dùng table variable / TVP, `WHILE` / cursor / CTE đệ quy, hoặc `TRY...CATCH`.

**PostgreSQL function attributes & `BEGIN ATOMIC`:**
- `IMMUTABLE` (cùng input → cùng kết quả *mãi*, không đọc bảng), `STABLE` (ổn trong 1 statement, đọc bảng được), `VOLATILE` (mặc định). Sai `IMMUTABLE` trên hàm đọc bảng / `now()` = expression index **sai** — [functions.md](functions.md) §11.
- `STRICT` (`RETURNS NULL ON NULL INPUT`): gặp bất kỳ đối số `NULL` nào là trả `NULL` ngay không chạy body.
- `LEAKPROOF` (chỉ superuser đặt được): cam kết không lộ dữ liệu qua error/side-effect — bắt buộc để planner pushdown predicate qua view `security_barrier` / RLS.
- `COST` / `ROWS`: gợi ý chi phí và số hàng ước lượng cho planner (quan trọng cho SRF `plpgsql`, vốn mặc định ước lượng `ROWS 1000`).
- **PG 14+ `BEGIN ATOMIC ... END;`** (cho `LANGUAGE sql`): thay thế `AS $$ ... $$` dạng chuỗi; PG parse và **khóa dependency lúc `CREATE`** (ngăn `DROP TABLE`/`ALTER COLUMN` vô tình làm gãy hàm, đồng thời an toàn trước bẫy đổi `search_path`).

PG `LANGUAGE sql` đơn giản thường inline; `LANGUAGE plpgsql` thì không. SS: `WITH SCHEMABINDING` + deterministic cho persisted computed / indexed view.

### 5.2 Inline TVF vs MSTVF

Ba hình SQL Server, đừng trộn khi review plan:

| | Inline TVF | MSTVF | Scalar UDF |
|---|---|---|---|
| Cú pháp | `RETURNS TABLE AS RETURN (SELECT …)` | `RETURNS @t TABLE (…) BEGIN … END` | `RETURNS scalar BEGIN … END` |
| Optimizer | *Mở* như view có tham số — thống kê base, join elimination | Bức tường: historically 1 hàng, 2014+ **100**, interleaved **2017+** *sau* chạy | FROID **2019+** nếu đủ điều kiện; không thì RBAR |
| `OPTION` / nhiều statement | **Không** | Được (`INSERT…SELECT` + `OPTION (MAXRECURSION)`) | Được trong body |
| Side-effect | Không | Không (TVF) | Hạn chế |
| Dùng khi | Hầu hết TVF | *Phải* nhiều bước / hint nội bộ | Tính thuần, đo FROID |

**Inline TVF** — một `RETURN SELECT`:

```sql
CREATE OR ALTER FUNCTION dbo.OrdersOf(@cid int)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
(
    SELECT Id, Total
    FROM dbo.Orders
    WHERE CustomerId = @cid
);

-- Caller: APPLY / JOIN như view
SELECT c.Id, o.Total
FROM dbo.Customers AS c
CROSS APPLY dbo.OrdersOf(c.Id) AS o;
```

Recursive CTE trong inline TVF: `MAXRECURSION` **không** đặt trong `RETURN (…)` — đặt ở *câu gọi*:

```sql
SELECT * FROM dbo.WalkFrom(@root)
OPTION (MAXRECURSION 0);
```

**MSTVF** — bảng biến trả về, nhiều statement:

```sql
CREATE OR ALTER FUNCTION dbo.OrdersOfMs(@cid int)
RETURNS @t TABLE (Id int, Total decimal(12,2))
AS
BEGIN
    INSERT INTO @t (Id, Total)
    SELECT Id, Total FROM dbo.Orders WHERE CustomerId = @cid;
    RETURN;
END;
```

Interleaved execution (2017+) chạy MSTVF *lấy cardinality thật* rồi tối ưu phía ngoài — giúp, **không** biến MSTVF thành inline. `WHILE` / cursor trong MSTVF = RBAR trong bức tường.

Inline thắng MSTVF gần như luôn trên query set-based. MSTVF chỉ khi *phải* nhiều bước / `OPTION` nội bộ.

```sql
-- PostgreSQL: SRF / RETURNS TABLE — LANGUAGE sql STABLE thường inline
CREATE OR REPLACE FUNCTION orders_of(cid int)
RETURNS TABLE (id int, total numeric)
LANGUAGE sql
STABLE
AS $$
    SELECT id, total FROM orders WHERE customer_id = cid
$$;
```

`LANGUAGE plpgsql` + `RETURN QUERY` ≈ bức tường MSTVF (không inline). `FROM orders_of(c.id)` khi `c` là alias trái: table function có LATERAL ngầm; có thể viết tường minh để dễ đọc — [joins.md](joins.md).

**Ghi chú:** Review `RETURNS @t TABLE` + `WHILE` = cờ đỏ. Viết lại inline / CTE. Scalar UDF trong `WHERE` trên SS 2016- = RBAR; đo `SET STATISTICS TIME` / Query Store. Đừng “MSTVF cho dễ debug” trên hot path.

---

## 6. Trigger set-based

**Hình dung.** Một `INSERT` 10.000 hàng là **một phong bì**, không phải 10.000 lần bấm Save. SQL Server `inserted`/`deleted` là cả phong bì. Vòng `WHILE` “lấy TOP 1 từ inserted” đúng trên SSMS một hàng, sai hoặc cực chậm khi bulk.

PostgreSQL `FOR EACH ROW` gọi hàm **mỗi hàng** (được, nhưng đắt). `FOR EACH STATEMENT` một lần — muốn từng hàng thì `REFERENCING NEW TABLE`.

Một lệnh `INSERT`/`UPDATE`/`DELETE` 10k hàng = **một** lần bắn trigger (SS `AFTER` / PG `FOR EACH STATEMENT`) hoặc 10k lần hàm row (PG `FOR EACH ROW`). Logic phải đúng trên *tập*, không trên “hàng tôi vừa gõ SSMS”.

```sql
-- SQL Server: AFTER; inserted / deleted là bảng ảo N hàng
CREATE OR ALTER TRIGGER dbo.trg_orders_audit
ON dbo.Orders
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted)
        RETURN;
    INSERT INTO dbo.Audit (OrderId, Action)
    SELECT i.Id, N'upsert'
    FROM inserted AS i;
END;
```

**Cấm:**

```sql
-- SAI: giả định một hàng
SELECT @id = Id FROM inserted;
IF @@ROWCOUNT = 1
    UPDATE … WHERE Id = @id;

-- SAI: RBAR
DECLARE c CURSOR FOR SELECT Id FROM inserted;
```

`INSERT…SELECT` 10k hàng vẫn một lần trigger; `@@ROWCOUNT` đầu trigger có thể đã bị statement trước trong trigger làm lệch — đếm `inserted`. Không `CURSOR` / `WHILE` trên `inserted` trừ khi đo là hết cách.

Không có `BEFORE` row. Sửa dữ liệu trước ghi: `INSTEAD OF` (phổ biến trên view). Nested: server `nested triggers` (mặc định ON, sâu 32); database `RECURSIVE_TRIGGERS` (mặc định OFF) cho cùng bảng. `UPDATE` trên cột không đổi vẫn có thể bắn trigger — lọc `UPDATE(col)` / so `inserted` vs `deleted`.

```sql
-- PostgreSQL: hàm RETURNS trigger + CREATE TRIGGER
CREATE OR REPLACE FUNCTION trg_orders_audit()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO audit (order_id, action) VALUES (NEW.id, TG_OP);
    RETURN NEW;
END;
$$;

CREATE TRIGGER orders_audit
AFTER INSERT OR UPDATE ON orders
FOR EACH ROW
EXECUTE FUNCTION trg_orders_audit();
```

`EXECUTE FUNCTION` (từ **PG 11+**; `EXECUTE PROCEDURE` chỉ giữ để tương thích ngược). Hàm trigger khai báo không tham số ở chữ ký `CREATE FUNCTION f() RETURNS trigger` (hoặc `event_trigger`), nhưng khi gắn `CREATE TRIGGER ... EXECUTE FUNCTION f('a', 'b')` vẫn nhận được chuỗi đối số qua **`TG_ARGV[]`** (`TG_NARGS`).

| | `FOR EACH ROW` | `FOR EACH STATEMENT` |
|---|---|---|
| `NEW`/`OLD` | có (`BEFORE DELETE`: `NEW` là **`NULL`**!) | không (dùng transition table) |
| `BEFORE` | `INSERT`/`UPDATE`: `RETURN NEW` (sửa được `NEW`); **`BEFORE DELETE` BẮT BUỘC `RETURN OLD`** (`RETURN NEW` = `NULL` sẽ **âm thầm hủy xóa mọi hàng**!); `RETURN NULL` = hủy thao tác trên hàng đó | `RETURN NULL` |
| Burst 10k `INSERT` | 10k lần hàm | 1 lần |

Transition table (statement-level, PG 10+):

```sql
CREATE OR REPLACE FUNCTION trg_orders_audit_stmt()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO audit (order_id, action)
    SELECT id, 'I' FROM new_rows;
    RETURN NULL;
END;
$$;

CREATE TRIGGER orders_audit_s
AFTER INSERT ON orders
REFERENCING NEW TABLE AS new_rows
FOR EACH STATEMENT
EXECUTE FUNCTION trg_orders_audit_stmt();
```

Cùng ý `inserted`: một `INSERT…SELECT`, không vòng. `OLD TABLE` cho `DELETE`/`UPDATE`. Trên PG, transition table chỉ dùng cho **`AFTER` trigger** — **cấm hoàn toàn với mọi `BEFORE` và `INSTEAD OF` trigger** (và cũng không dùng được với `CONSTRAINT TRIGGER` hay trigger có `UPDATE OF col`).

**Thứ tự chạy nhiều trigger trên cùng bảng/sự kiện:** **PostgreSQL** chạy xác định theo **thứ tự bảng chữ cái (alphabet) của tên trigger**. **SQL Server** **không** đảm bảo thứ tự giữa các trigger; chỉ định được tối đa 1 trigger `First` và 1 trigger `Last` cho mỗi sự kiện `AFTER` bằng `EXEC sys.sp_settriggerorder`.

Test bắt buộc: `INSERT INTO t SELECT … FROM generate_series(1,1000)` / SS `INSERT … SELECT` 1000 hàng — trigger một hàng sẽ silent-sai trên burst.

**Ghi chú:** `BEFORE ROW` `RETURN NULL` nuốt hàng **không lỗi** (đặc biệt bẫy `RETURN NEW` trong `BEFORE DELETE`!). `AFTER` không đổi hàng đang ghi bằng `RETURN`. Mutating: trigger sửa cùng bảng → vòng; đo `pg_trigger_depth()` / `TRIGGER_NESTLEVEL()`. Không gọi REST / `AI_GENERATE_EMBEDDINGS` trong trigger OLTP.

---

## 7. Dynamic SQL & quoting

**Giá trị** → parameter. **Identifier** → quote function, không nối raw.

```sql
-- SQL Server
DECLARE @sql nvarchar(max) =
    N'SELECT Total FROM '
    + QUOTENAME(@schema) + N'.' + QUOTENAME(@table)
    + N' WHERE Id = @id';
EXEC sys.sp_executesql
    @sql,
    N'@id int',
    @id = @id;
```

`QUOTENAME(@x)` mặc định bọc `[…]` và trả về `nvarchar(258)`. Hàm trả **`NULL` khi input > 128 ký tự** (giới hạn `sysname`) hoặc ký tự quote không hợp lệ — phải kiểm tra `NULL` trước `EXEC` (vì nối chuỗi với `NULL` làm `@sql = NULL`, và `sp_executesql NULL` im lặng không chạy gì).

```sql
-- PostgreSQL
EXECUTE format(
    'SELECT total FROM %I.%I WHERE id = $1',
    schema_name,
    table_name
)
USING id;
```

`format`: `%I` identifier (quote `"…"`), `%L` literal SQL (`NULL` → `NULL` không quote), `%s` chèn thô — **cấm** `%s` với user input. `quote_ident` / `quote_literal` tương đương thủ công.

Không:

```sql
-- CẢ HAI: injection
EXECUTE 'SELECT * FROM ' || user_table;
SET @sql = N'SELECT * FROM ' + @table;
```

Trên SQL Server, `sp_executesql` giữ plan trong cache theo text đã parameterize. Trên PostgreSQL, PL/pgSQL `EXECUTE ... USING` tách giá trị khỏi câu SQL để chống injection, **nhưng không bao giờ cache plan** (mỗi lần chạy đều parse và plan lại — muốn cache plan cần static SQL trong PL/pgSQL hoặc `PREPARE`/`EXECUTE` ở tầng SQL). Nối literal giá trị vào chuỗi → cache nổ + injection.

PL/pgSQL `EXECUTE` khác T-SQL `EXECUTE(@sql)` (ad-hoc) và khác `EXECUTE proc`. Tên trùng: trong PL luôn `EXECUTE format` cho dynamic SQL, `CALL` cho procedure.

**Ghi chú:** Danh sách cột do user chọn: whitelist so khớp catalog (`pg_catalog` / `sys.columns`), rồi `%I` từng tên. Không `QUOTE` cả `SELECT *`.

---

## 8. Optimized `sp_executesql` (compilation storm)

**Hình dung.** Mở app, 500 connection cùng gửi một câu parameterized chưa có trong cache. Mỗi connection **tự biên** plan — CPU optimizer bão. 2025 `OPTIMIZED_SP_EXECUTESQL`: một người biên, người khác **xếp hàng rồi dùng chung** bản đã biên. Không làm plan *đúng hơn* (sniffing vẫn còn); chỉ hết cảnh 500 người biên cùng lúc.

Lịch sử: nhiều session cùng **text** `sp_executesql` (khác parameter) **compile song song**, mỗi session nhét một bản plan — CPU optimizer nhảy, plan cache phình, cold cache sau failover/restart thành storm.

**2025:** database scoped `OPTIMIZED_SP_EXECUTESQL` — compile `sp_executesql` *serialize* giống stored procedure / trigger:

1. Session đầu lấy compile lock, compile, nhét plan cache.
2. Session khác chờ lock; khi plan có sẵn thì **bỏ chờ** và **reuse**.

```sql
ALTER DATABASE SCOPED CONFIGURATION SET OPTIMIZED_SP_EXECUTESQL = ON;
```

Mặc định **OFF**. Chỉ `sp_executesql` — **không** phủ ad-hoc không parameter, proc, hay batch text *khác nhau*. Không sửa chất lượng plan / sniffing.

Khi bật, Learn khuyên kèm auto-update stats bất đồng bộ + chờ ưu tiên thấp, giảm lock compile dài + `WAIT_ON_SYNC_STATISTICS_REFRESH` / `LCK_M_X`:

```sql
ALTER DATABASE SCOPED CONFIGURATION
    SET ASYNC_STATS_UPDATE_WAIT_AT_LOW_PRIORITY = ON;
```

(`ASYNC_STATS_UPDATE_WAIT_AT_LOW_PRIORITY` có từ 2022; `OPTIMIZED_SP_EXECUTESQL` chỉ **2025** / Azure SQL / Fabric.)

Không thay `optimize for ad hoc workloads`. ORM gửi cùng batch parameterized ồ ạt: đo compile CPU / `sql_handle` trước-sau; query compile chậm — session khác **chờ** lần đầu (đổi latency cold).

PostgreSQL: `PREPARE` / generic plan (`plan_cache_mode = force_generic_plan` khi đo được). PG 19: `pg_plan_advice`, `pg_stash_advice` ổn định plan — **không** có switch cùng tên `OPTIMIZED_SP_EXECUTESQL`.

**Ghi chú:** Bật scoped config trên prod = đổi hành vi compile. Đo trước-sau. Không phải license AI. Không biến dynamic SQL thành an toàn nếu vẫn nối chuỗi.

---

## 9. `sp_invoke_external_rest_endpoint`

Gọi **HTTPS** từ engine. Rủi ro exfiltration — least privilege, audit, không nhét secret vào body proc.

```sql
-- Box 2025 / MI (SQL Server 2025 policy): mặc định TẮT
EXECUTE sp_configure 'external rest endpoint enabled', 1;
RECONFIGURE WITH OVERRIDE;          -- cần ALTER SETTINGS (sysadmin/serveradmin)

GRANT EXECUTE ANY EXTERNAL ENDPOINT TO app_user;
```

Azure SQL Database / Fabric: thường **bật sẵn**; allow-list host — host lạ đi qua API Management, không phải URL internet tùy ý.

```sql
DECLARE @resp nvarchar(max);
DECLARE @rc  int;

EXEC @rc = sys.sp_invoke_external_rest_endpoint
    @url         = N'https://example.invalid/api',   -- nvarchar(4000), HTTPS
    @method      = N'POST',          -- GET|POST|PUT|PATCH|DELETE|HEAD; mặc định POST
    @headers     = N'{"Content-Type":"application/json"}',  -- JSON phẳng, nvarchar(4000)
    @payload     = N'{"q":"orders"}', -- nvarchar(max): JSON / XML / text
    @timeout     = 30,               -- smallint 1–230; mặc định 30; cộng dồn nếu retry
    @retry_count = 0,                -- tinyint 0–10; 0 = không retry
    @credential  = NULL,             -- DATABASE SCOPED CREDENTIAL (tùy)
    @response    = @resp OUTPUT;     -- nvarchar(max)
```

`@rc = 0` nếu HTTP 2xx. Khác 2xx → `@rc` = status code. Không gọi được HTTPS → **exception**. `@response` JSON dạng `{ "response": { "status": { "http": { "code", "description" } }, "headers": {} }, "result": {} }` — `result` bỏ nếu 204.

Forbidden request headers bị bỏ/thay dù truyền trong `@headers`. Retry: tôn trọng `Retry-After`; không thì exponential backoff một số mã; khác: 200 ms.

Timeout / retry / mạng **trong txn** = lock kéo dài. Secret: credential / Key Vault, không literal. Trigger + REST = timeout × hàng.

PostgreSQL: **không** có `sp_invoke_external_rest_endpoint`. Extension `http` / app layer / FDW. Đừng bịa tên proc.

**Ghi chú:** Gọi từ proc background / service, không từ `AFTER INSERT` OLTP. `@url` 4000 ký tự — không nhét payload vào URL.

---

## 10. `CREATE EXTERNAL MODEL`

Đăng ký endpoint embedding trong catalog. Hàm `AI_GENERATE_EMBEDDINGS` / `AI_GENERATE_CHUNKS` dùng *tên model*, không URL rải query — [functions.md](functions.md) §9.

```sql
CREATE EXTERNAL MODEL Ada2Embeddings
[ AUTHORIZATION owner_name ]
WITH (
    LOCATION    = N'https://my-endpoint.cognitiveservices.azure.com/openai/deployments/text-embedding-ada-002/embeddings?api-version=2023-05-15',
    API_FORMAT  = 'Azure OpenAI',     -- Azure OpenAI | OpenAI | Ollama | ONNX Runtime
    MODEL_TYPE  = EMBEDDINGS,         -- hiện chỉ EMBEDDINGS
    MODEL       = 'text-embedding-ada-002',
    CREDENTIAL  = [https://my-endpoint.cognitiveservices.azure.com/],
    PARAMETERS  = '{"dimensions":1536}'
    -- LOCAL_RUNTIME_PATH = '…'       -- chỉ ONNX Runtime
);

ALTER EXTERNAL MODEL Ada2Embeddings SET (MODEL = 'text-embedding-3-small');
DROP EXTERNAL MODEL Ada2Embeddings;
```

Tên unique trong database. Không `AUTHORIZATION` → owner = user hiện tại. Quyền dùng model tách EXECUTE hàm. `PARAMETERS` JSON append vào request (ví dụ `dimensions`). Credential: database scoped — cùng họ `sp_invoke_external_rest_endpoint`.

MI: cần update policy **Always-up-to-date** (Learn). Không hard-code API key trong `LOCATION`.

PostgreSQL: không `CREATE EXTERNAL MODEL`. App / extension gọi API, ghi `vector` pgvector.

**Ghi chú:** Model + REST cùng rủi ro mạng. Batch chunk (`AI_GENERATE_CHUNKS`) rồi embed — đừng `SELECT AI_GENERATE_EMBEDDINGS(cột_max)` không cắt. Trigger OLTP: cấm.

---

## 11. Quyền: `SECURITY DEFINER` & `search_path`

**Hình dung.** `SECURITY INVOKER` = hàm chạy bằng quyền **người gọi**. `SECURITY DEFINER` = hàm chạy bằng quyền **chủ hàm** (thường superuser/admin) — tiện kiểm tra mật khẩu, nguy hiểm nếu tên bảng không khóa.

PostgreSQL tìm `pwds` theo `search_path`. Attacker tạo **bảng tạm cùng tên** nằm *trước* schema admin → hàm definer đọc nhầm bảng attacker, vẫn với quyền admin. Chữa: `SET search_path = admin, pg_temp` (`pg_temp` **cuối**) và viết `admin.pwds`, không viết `pwds`.

SQL Server tương tự: `EXECUTE AS OWNER` + dynamic SQL không `QUOTENAME` = leo quyền. [dialects.md](dialects.md).

```sql
GRANT EXECUTE ON dbo.GetOrders TO app_user;
GRANT EXECUTE ON FUNCTION tax(numeric) TO app_user;
```

Caller chỉ cần `EXECUTE`; routine đọc bảng bằng quyền **invoker** (mặc định) hoặc **definer**.

**PostgreSQL `SECURITY DEFINER`:** chạy với chủ sở hữu. Chuỗi `search_path` mặc định là `"$user", public` — tuy `pg_temp` không viết trong chuỗi đó, nhưng nếu chưa xuất hiện tường minh, PostgreSQL **ngầm tìm `pg_temp` đầu tiên cho table/view/type** (còn function/operator thì không tự tìm `pg_temp`). Attacker vẫn có thể tạo temp table trùng tên để đánh lừa query trong hàm definer → leo quyền. Chuẩn an toàn là ghim `SET search_path = admin, pg_temp` (`pg_temp` **cuối** để chặn tìm ngầm đầu tiên) và qualify đầy đủ `schema.table`.

```sql
CREATE OR REPLACE FUNCTION check_password(uname text, pass text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = admin, pg_temp          -- trusted schema, pg_temp CUỐI
AS $$
DECLARE passed boolean;
BEGIN
    SELECT (pwd = pass) INTO passed
    FROM admin.pwds                       -- qualify
    WHERE username = uname;
    RETURN passed;
END;
$$;

REVOKE ALL ON FUNCTION check_password(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION check_password(text, text) TO app_login;
```

Docs 19: `pg_temp` **cuối** path. Qualify mọi relation. Definer **không** `COMMIT` trong procedure. `SET search_path` trên `CREATE` cũng chặn txn control trong procedure.

**SQL Server `EXECUTE AS`:**

```sql
CREATE OR ALTER PROCEDURE dbo.GetOrders
WITH EXECUTE AS OWNER          -- hoặc SELF / CALLER / 'user'
AS
…
```

`OWNER` ≈ definer. Default schema của user impersonate + synonym = bẫy tên. **Sandbox & Cross-DB:** mọi `EXECUTE AS` ở mức module bị đóng **sandbox trong chính database hiện tại** (không truy cập được DB khác hay quyền cấp server). **Tuyệt đối tránh bật `TRUSTWORTHY ON`** để vượt sandbox (vì `db_owner` có thể leo quyền lên `sysadmin`!). Cách an toàn chuẩn cho cross-DB / quyền đặc biệt là **Module Signing** (`CREATE CERTIFICATE` + `ADD SIGNATURE TO dbo.Proc BY CERTIFICATE ...` + tạo user/login từ certificate và cấp đúng quyền tối thiểu) — chi tiết [permissions.md](permissions.md). Dynamic SQL trong `EXECUTE AS OWNER` vẫn injection nếu nối identifier — quyền *cao hơn* + injection = mất DB.

**Ghi chú:** Review mọi `SECURITY DEFINER` / `EXECUTE AS OWNER`: `SET search_path` (PG), schema cố định (SS), không `%s` / string-concat identifier, `PUBLIC` đã revoke. Mô hình `GRANT`/`DENY`/RLS: [permissions.md](permissions.md).

---

## 12. Worked examples

**Inline TVF thay MSTVF**

```sql
-- Trước (MSTVF): plan ngoài thấy ~100 hàng
CREATE FUNCTION dbo.OpenOrdersMs(@cid int)
RETURNS @t TABLE (Id int, Total decimal(12,2))
AS
BEGIN
    INSERT INTO @t SELECT Id, Total FROM dbo.Orders
    WHERE CustomerId = @cid AND Status = N'open';
    RETURN;
END;

-- Sau: inline
CREATE OR ALTER FUNCTION dbo.OpenOrders(@cid int)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
(
    SELECT Id, Total
    FROM dbo.Orders
    WHERE CustomerId = @cid AND Status = N'open'
);
```

**Trigger burst-safe hai dialect**

```sql
-- SS: một INSERT từ inserted
INSERT INTO dbo.OrderTax (OrderId, Tax)
SELECT i.Id, dbo.Tax(i.Total)
FROM inserted AS i;

-- PG statement-level
INSERT INTO order_tax (order_id, tax)
SELECT id, tax(total) FROM new_rows;
```

Scalar `dbo.Tax` trên 10k hàng: đo FROID; tốt hơn: `i.Total * 0.10` trong `SELECT` hoặc computed.

**ORM storm + REST tách tầng**

```sql
-- Session: bật serialize compile (không sửa sniffing)
ALTER DATABASE SCOPED CONFIGURATION SET OPTIMIZED_SP_EXECUTESQL = ON;

-- Gọi HTTP từ proc *ngắn txn* / sau COMMIT — không trong trigger
-- Embedding: CREATE EXTERNAL MODEL + AI_GENERATE_EMBEDDINGS, không tự ghép URL
```

---

## 13. Lỗi: `TRY`/`CATCH` vs `EXCEPTION`

```sql
-- T-SQL: XACT_ABORT ON → trong TRY...CATCH, lỗi nghiêm trọng biến txn thành doomed (XACT_STATE() = -1)
SET XACT_ABORT ON;
BEGIN TRY
    BEGIN TRAN;
    EXEC dbo.P @id = 1;
    COMMIT;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRAN;   -- 1 = committable, -1 = doomed (bắt buộc rollback), 0 = không có txn
    THROW;                                -- giữ nguyên số lỗi gốc; RAISERROR không phải rethrow đúng
END CATCH;

-- PL/pgSQL: lỗi abort txn; EXCEPTION = savepoint ẩn quanh block
BEGIN
    CALL p(1);                            -- p là PROCEDURE → bắt buộc CALL (PERFORM chỉ cho FUNCTION!)
EXCEPTION
    WHEN unique_violation THEN
        RAISE NOTICE 'dup';
    WHEN OTHERS THEN
        RAISE;
END;
```

Function PG **không** `COMMIT`/`ROLLBACK` trong `EXCEPTION`. Procedure PG `COMMIT` trong `EXCEPTION` chỉ khi không definer / không `SET` clause — dễ vỡ; đưa txn ra caller.

SS: `CATCH` không bắt compile error / kill. Kiểm `XACT_STATE()` trong `CATCH` khi bật `SET XACT_ABORT ON`: nếu `XACT_STATE() = -1` (uncommittable) thì không được `COMMIT` hay rollback về savepoint, bắt buộc `ROLLBACK TRAN` toàn bộ. `THROW` không đối số chỉ trong `CATCH`. `@@ERROR` sau statement, không stack như PG `GET STACKED DIAGNOSTICS`.

Trigger: lỗi trong trigger SS rollback statement (và txn nếu `XACT_ABORT`); PG `EXCEPTION` trong hàm trigger nuốt thì hàng vẫn ghi trừ khi `RAISE`. Đừng nuốt `unique_violation` trong trigger audit rồi nghĩ “không sao”.

---

## 14. `EXEC(@sql)` vs `sp_executesql` vs `PREPARE`

| | Plan cache | Parameter | Compilation storm 2025 |
|---|---|---|---|
| SS `EXEC(@sql)` / `EXECUTE(@sql)` | ad-hoc; text khác = plan khác | nối chuỗi → injection + cache nổ | **không** vào `OPTIMIZED_SP_EXECUTESQL` |
| SS `sp_executesql` | cache theo text đã parameterize | `@p` | **có** khi scoped ON |
| PG PL/pgSQL `EXECUTE format … USING` | **không bao giờ cache plan** (parse & plan lại mỗi lần gọi) | `$1` | — |
| PG SQL `PREPARE`/`EXECUTE` | generic vs custom (`plan_cache_mode`) | `$1` | `pg_plan_advice` **19** |

`optimize for ad hoc workloads` (SS) stub plan lần đầu — khác serialize compile. Dùng cả hai khi đo được: ad-hoc rác *và* ORM `sp_executesql` trùng text.

TVP (SS) / array (PG) thay list `IN (1,2,3)` dựng dynamic. `STRING_AGG` id rồi `IN` chuỗi = injection + không kiểu.

---

## 15. Best practices & checklist


- `SET NOCOUNT ON` + `SET XACT_ABORT ON` đầu proc T-SQL.
- Result set PG: function `RETURNS TABLE`, không nhét `SELECT` trong procedure mong client nhận như SSMS.
- TVF: inline; tránh MSTVF / scalar trong `WHERE`.
- PG: nhãn `IMMUTABLE`/`STABLE`/`VOLATILE` thật; `PARALLEL SAFE` khi đúng.
- Trigger: một `INSERT…SELECT` từ `inserted` / transition table; test 1000 hàng; không `WHILE`.
- Dynamic SQL: `sp_executesql` / `USING` + `QUOTENAME` / `%I`.
- 2025: cân nhắc `OPTIMIZED_SP_EXECUTESQL` khi ORM gửi cùng batch parameterized — đo compile storm, không kỳ vọng plan đẹp hơn.
- REST/AI: ngoài txn nóng; credential; timeout; box 2025 cần `sp_configure`.
- Definer: `search_path` chốt; `REVOKE PUBLIC`; qualify tên bảng.
- Không `COMMIT` trong proc SS nếu caller đang mở txn (trừ khi API rõ).

```text
□ NOCOUNT / XACT_ABORT (SS)
□ TVF inline không MSTVF
□ Trigger set-based + test burst
□ Quoting identifier
□ SECURITY DEFINER + search_path, pg_temp cuối
□ Không REST trong trigger
□ IMMUTABLE không gọi now()
□ OPTIMIZED_SP_EXECUTESQL ≠ sửa sniffing
□ EXTERNAL MODEL + credential, không key trong proc
```

---

## 16. Bẫy khi review

- MSTVF “cho dễ debug” trên hot path.
- Scalar UDF `WHERE dbo.fn(col) = 1` (pre-inline).
- Trigger giả định một hàng (`SELECT @id = Id FROM inserted`).
- `WHILE` trên `inserted`.
- `FOR EACH ROW` trên bảng ingest 10k hàng/statement không đo.
- Thiếu `SET NOCOUNT ON` → client “records affected” lệch.
- `COMMIT` trong proc khi `@@TRANCOUNT > 1`.
- PG function `COMMIT`.
- `CALL` proc có `COMMIT` từ trong `BEGIN` txn.
- `LANGUAGE plpgsql IMMUTABLE` đọc bảng.
- `EXECUTE '…' || table_name`.
- `%s` trong `format` với input user.
- `QUOTENAME` trả `NULL` (input > 128 ký tự) làm `@sql` thành `NULL` → `sp_executesql NULL` im lặng không làm gì.
- `BEFORE DELETE` trên PG viết `RETURN NEW` (vốn là `NULL`) → âm thầm hủy xóa mọi hàng (phải `RETURN OLD`).
- Quên `OUTPUT` ở câu lệnh `EXEC` gọi proc T-SQL, hoặc dùng `SELECT @n = ...` trong vòng lặp mà không reset biến khi 0 hàng.
- Bật `TRUSTWORTHY ON` để vượt sandbox `EXECUTE AS` (leo quyền `db_owner` → `sysadmin`; dùng Module Signing thay thế).
- `SECURITY DEFINER` không `SET search_path`, để `pg_temp` tìm ngầm đầu tiên.
- `GRANT EXECUTE … TO PUBLIC`.
- `sp_invoke_external_rest_endpoint` chưa `sp_configure` (box 2025).
- REST trong trigger / cursor.
- `CREATE EXTERNAL MODEL` nhét key vào `LOCATION`.
- `EXECUTE PROCEDURE` trigger trên PG mới — dùng `EXECUTE FUNCTION`.
- Nested trigger recursion bất ngờ (`RECURSIVE_TRIGGERS ON`).
- Parameter sniffing: plan “mãi mãi” theo `@id = 1`.
- Tin `OPTIMIZED_SP_EXECUTESQL` sửa sniffing (nó sửa *compilation storm*).
- `OPTION (MAXRECURSION)` trong định nghĩa inline TVF.
- `EXEC(@sql)` nghĩ đã được `OPTIMIZED_SP_EXECUTESQL`.
- Nuốt `EXCEPTION` trong hàm trigger rồi hàng vẫn commit.
- `INSTEAD OF` quên `INSERT` vào bảng gốc.

---

## 17. Version gates

| Mục | SQL Server | PostgreSQL |
|---|---|---|
| `CREATE OR ALTER PROCEDURE` | 2016+ | `CREATE OR REPLACE` lâu |
| Scalar UDF inlining (FROID) | **2019+** (`WITH INLINE`, `is_inlineable`) | SQL-language inline lâu |
| SQL-standard body `BEGIN ATOMIC ... END;` | — | **14+** (parse & track dependency lúc `CREATE`) |
| Interleaved execution MSTVF | **2017+** | — |
| `THROW` | 2012+ | `RAISE` |
| `EXECUTE FUNCTION` trigger | — | **11+** (khuyên dùng) |
| Transition tables | `inserted`/`deleted` | **10+** `REFERENCING … TABLE` |
| `SECURITY DEFINER` | `EXECUTE AS` | lõi function/proc |
| `format(%I,%L)` | — | lõi |
| `QUOTENAME` / `sp_executesql` | lõi | `EXECUTE … USING` |
| `OPTIMIZED_SP_EXECUTESQL` | **2025** (scoped, default OFF) | `PREPARE` / `plan_cache_mode` |
| OPPO (optional param plan) | **2025** | custom/generic plan |
| `sp_invoke_external_rest_endpoint` | **2025** (box/MI: `sp_configure`) | — |
| `CREATE EXTERNAL MODEL` / `AI_GENERATE_*` | **2025** | — |
| `pg_plan_advice` / `pg_stash_advice` | — | **19** |
| Procedure `COMMIT` | luôn (txn T-SQL) | 11+; không definer / không `SET` |

Built-in, window, CTE trong body routine: [functions.md](functions.md), [window-functions.md](window-functions.md), [cte-subqueries.md](cte-subqueries.md).

---

## Phụ lục A. `INSTEAD OF` vs `BEFORE`

SQL Server không `BEFORE ROW`. Sửa giá trị trước ghi lên bảng base: computed / default / constraint, hoặc `INSTEAD OF` trên **view** (bắt buộc tự `INSERT` vào bảng gốc). `INSTEAD OF` trên bảng: thay statement gốc — quên `INSERT INTO base SELECT * FROM inserted` = mất dữ liệu im lặng.

```sql
CREATE OR ALTER TRIGGER dbo.trg_v_orders_io
ON dbo.v_orders
INSTEAD OF INSERT
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO dbo.Orders (CustomerId, Total)
    SELECT CustomerId, Total FROM inserted;
END;
```

PostgreSQL `BEFORE ROW`: sửa `NEW.col`, `RETURN NEW` (riêng `BEFORE DELETE` bắt buộc `RETURN OLD`). `INSTEAD OF` trên PG chỉ dùng trên **view** (PG 9.1+) và **chỉ hỗ trợ `FOR EACH ROW`** (không hỗ trợ `FOR EACH STATEMENT` và không dùng trên table). `BEFORE STATEMENT` không có `NEW`.

Sâu: SS nested trigger 32; `TRIGGER_NESTLEVEL()`. PG `pg_trigger_depth()`. Cả hai: trigger sửa cùng bảng + recursive ON = vòng. Audit tách bảng, không `UPDATE` lại hàng đang `inserted`.

---

## Nguồn chính thức

Đối chiếu ngày **21/11/2026**. PostgreSQL **19** GA **19/11/2026**. SQL Server 2025 **CU11** (12/11/2026): fuzzy GA; vector index, `VECTOR_SEARCH`, half-precision và CES vẫn PREVIEW. Xem [baseline và quy ước ví dụ](README.md#trạng-thái-phiên-bản-và-cách-kiểm-chứng).

- [PL/pgSQL INTO / STRICT / EXECUTE](https://www.postgresql.org/docs/19/plpgsql-statements.html)
- [T-SQL sp_executesql](https://learn.microsoft.com/en-us/sql/relational-databases/system-stored-procedures/sp-executesql-transact-sql?view=sql-server-ver17)
