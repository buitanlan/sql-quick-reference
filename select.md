# SELECT

> **Baseline:** SQL Server **2025** (17.x) · PostgreSQL **19**.  
> Thứ tự **viết** ≠ thứ tự **thực thi**. Logical processing quyết định alias nào tồn tại, `WHERE` vs `HAVING`, và window tính lúc nào — đây là nguồn bug hay gặp khi port và khi debug “sao `WHERE y` lỗi”.

`SELECT` không phải “lấy cột rồi lọc”. Engine dựng một bảng ảo qua từng bước: nguồn → lọc hàng → gộp → lọc nhóm → chiếu cột / window → sắp → cắt. Hai dialect cùng ISO ở bề mặt (`FETCH`, `GROUPING SETS`) nhưng lệch ở `TOP`/`LIMIT`, `DISTINCT ON`, so sánh tuple, và SQL/PGQ (`GRAPH_TABLE`, PostgreSQL **19**, **beta** đến GA). Đừng copy câu từ một engine rồi cho rằng plan và ngữ nghĩa giống nhau.

Sargable, phân trang, khóa hàng: [indexes.md](indexes.md), [joins.md](joins.md), [concurrency.md](concurrency.md). CTE / subquery: [cte-subqueries.md](cte-subqueries.md). Window: [window-functions.md](window-functions.md). Optimizer/IQP ảnh hưởng **plan** `SELECT` (không đổi logical processing): mục 14 và [internal.md](internal.md) §13.

---

## Mục lục

- [1. Tổng quan \& triết lý](#1-tổng-quan--triết-lý)
- [2. Hình dạng câu lệnh](#2-hình-dạng-câu-lệnh)
- [3. Logical processing](#3-logical-processing)
  - [3.0 Hình dung: bếp, không phải đọc kịch bản](#30-hình-dung-bếp-không-phải-đọc-kịch-bản)
  - [3.1 Thứ tự logic](#31-thứ-tự-logic)
  - [3.2 Alias, HAVING, window](#32-alias-having-window)
  - [3.3 DISTINCT so với LIMIT](#33-distinct-so-với-limit)
- [4. FROM \& table source](#4-from--table-source)
- [5. WHERE \& sargable](#5-where--sargable)
- [6. GROUP BY, HAVING, CUBE](#6-group-by-having-cube)
  - [6.1 Functional dependency](#61-functional-dependency)
  - [6.2 GROUPING SETS / CUBE / ROLLUP](#62-grouping-sets--cube--rollup)
  - [6.3 GROUP BY ALL (PostgreSQL 19)](#63-group-by-all-postgresql-19)
- [7. SELECT list](#7-select-list)
- [8. ORDER BY, FETCH vs TOP vs LIMIT](#8-order-by-fetch-vs-top-vs-limit)
  - [8.1 WITH TIES và PERCENT](#81-with-ties-và-percent)
  - [8.2 OFFSET sâu](#82-offset-sâu)
- [9. Keyset pagination](#9-keyset-pagination)
- [10. DISTINCT \& DISTINCT ON vs ROW\_NUMBER](#10-distinct--distinct-on-vs-row_number)
- [11. GRAPH\_TABLE (PostgreSQL 19)](#11-graph_table-postgresql-19)
  - [11.1 Metadata, không storage riêng](#111-metadata-không-storage-riêng)
  - [11.2 MATCH một hop và nhiều hop cố định](#112-match-một-hop-và-nhiều-hop-cố-định)
  - [11.3 Rewrite thành join — EXPLAIN](#113-rewrite-thành-join--explain)
  - [11.4 Giới hạn 19 (chưa có)](#114-giới-hạn-19-chưa-có)
  - [11.5 SQL Server MATCH ≠ SQL/PGQ](#115-sql-server-match--sqlpgq)
- [12. TABLESAMPLE](#12-tablesample)
- [13. FOR UPDATE — con trỏ khóa](#13-for-update--con-trỏ-khóa)
- [14. Plan SELECT: IQP 2025 \& PG 19](#14-plan-select-iqp-2025--pg-19)
  - [14.1 DOP feedback](#141-dop-feedback)
  - [14.2 CE feedback trên biểu thức](#142-ce-feedback-trên-biểu-thức)
  - [14.3 OPPO / PSPO — tham số tùy chọn](#143-oppo--pspo--tham-số-tùy-chọn)
  - [14.4 Query Store secondary](#144-query-store-secondary)
- [15. Worked examples](#15-worked-examples)
- [16. Best practices \& checklist](#16-best-practices--checklist)
- [17. Bẫy khi review](#17-bẫy-khi-review)
- [18. Version gates](#18-version-gates)

---

## 1. Tổng quan & triết lý

Câu `SELECT` là biểu thức bảng: đầu vào là table source, đầu ra là result set (có thể không có tên, không có khóa). Optimizer **được** đổi thứ tự vật lý (predicate pushdown, join reorder, aggregate trước join) miễn **kết quả logic** giữ nguyên. Đó là lý do `SET enable_hashjoin` hay `OPTION (LOOP JOIN)` chỉ là gợi ý vật lý — không sửa ngữ nghĩa sai.

Ba nguyên tắc khi viết và review:

- **Determinism:** không `ORDER BY` thì thứ tự **không xác định**. `TOP`/`LIMIT`/`FETCH` không biến kết quả thành ổn định.
- **NULL:** `WHERE` loại `UNKNOWN`. So sánh, `IN`, `DISTINCT` đều theo three-valued logic — [dialects.md](dialects.md), [operators.md](operators.md).
- **Seek vs scan:** predicate sargable + index phù hợp mới cho keyset / nested loop. Bọc cột trong hàm = “đúng kết quả, sai plan”.

PostgreSQL 19 còn **beta** (GA mục tiêu cuối 10/2026): `GRAPH_TABLE`, `GROUP BY ALL`, và vài rewrite `GROUP BY` có thể chỉnh trước GA — đối chiếu [release notes 19](https://www.postgresql.org/docs/19/release-19.html). SQL Server 2025: IQP (DOP feedback **ON mặc định**, CE expression, OPPO) đổi **plan** `SELECT` khi compat **170**, không đổi thứ tự logic mục 3.

---

## 2. Hình dạng câu lệnh

```sql
WITH cte AS ( ... )                          -- tùy chọn; xem cte-subqueries.md
SELECT [DISTINCT] select_list
FROM table_source
WHERE predicate
GROUP BY ...
HAVING predicate
WINDOW w AS ( ... )                          -- PostgreSQL / SQL:2011; SQL Server: inline OVER
ORDER BY ...
OFFSET n ROWS FETCH NEXT m ROWS ONLY;
```

Dialect — **không** trộn `TOP` với `OFFSET`/`FETCH` trên SQL Server (chi tiết mục 8):

```sql
-- SQL Server
SELECT TOP (10) WITH TIES * FROM dbo.Orders ORDER BY Total DESC;
SELECT * FROM dbo.Orders ORDER BY Total DESC, Id DESC
OFFSET 0 ROWS FETCH NEXT 10 ROWS ONLY;

-- PostgreSQL: LIMIT … OFFSET …  hoặc  FETCH FIRST n ROWS [WITH TIES]
SELECT * FROM orders ORDER BY total DESC, id DESC LIMIT 10 OFFSET 0;
```

**Ghi chú:** `WINDOW` đặt tên frame dùng lại trong `SELECT` — PostgreSQL. SQL Server viết `OVER (...)` tại mỗi hàm. Chi tiết frame: [window-functions.md](window-functions.md). `GRAPH_TABLE (...)` đứng chỗ table source trong `FROM`, không phải hàm trong select list.

---

## 3. Logical processing

SQL **không** chạy từ trên xuống như ngôn ngữ thủ tục. Bạn viết `SELECT` trước, engine **nghĩ** `FROM` trước. Đây là nguồn “sao `WHERE y` lỗi trong khi `ORDER BY y` được”.

### 3.0 Hình dung: bếp, không phải đọc kịch bản

Mỗi câu `SELECT` là một **dây chuyền**. Khối sau chỉ được dùng thứ khối trước đã làm ra.

```text
  FROM/JOIN     →  một bảng ảo (nhân hàng, NULL outer)
       ↓
  WHERE         →  loại hàng (không thấy alias SELECT, không thấy SUM)
       ↓
  GROUP BY      →  gộp thành nhóm; hàng lẻ biến mất
       ↓
  HAVING        →  loại *nhóm* (được SUM, không phải lọc hàng gốc)
       ↓
  WINDOW        →  đánh số / cộng dồn *trên tập còn lại* (không gộp mất hàng)
       ↓
  SELECT list   →  đặt tên cột, DISTINCT, biểu thức
       ↓
  ORDER BY      →  sắp (được alias SELECT)
       ↓
  OFFSET/FETCH  →  cắt trang
```

Optimizer **được** đảo thứ tự vật lý (đẩy `WHERE` vào join, hash thay loop) miễn **kết quả logic** giống dây chuyền trên. `EXPLAIN` nói *làm thế nào*; dây chuyền nói *kết quả phải thế nào*. Tranh cãi “mất hàng” → vẽ dây chuyền, không tranh hash vs nested loop trước.

Ví dụ gắn dây chuyền:

```sql
SELECT department, SUM(amount) AS total
FROM payments          -- 1. mọi payment
WHERE status = 'ok'    -- 2. loại failed (không dùng SUM)
GROUP BY department    -- 3. mỗi phòng một nhóm
HAVING SUM(amount) > 0 -- 4. loại phòng tổng ≤ 0
ORDER BY total DESC;   -- 7. alias total đã có sau bước 6
```

`WHERE total > 0` sai vì `total` chưa sinh. `WHERE SUM(amount) > 0` sai vì aggregate thuộc bước 4.

### 3.1 Thứ tự logic

Thứ tự **logic** (rút gọn, cả hai engine):

1. `FROM` / `JOIN` / `APPLY` / `LATERAL` / `GRAPH_TABLE` (tích, lọc `ON`)
2. `WHERE`
3. `GROUP BY`
4. `HAVING`
5. `WINDOW` (tính `OVER`)
6. `SELECT` list (alias, biểu thức, `DISTINCT`)
7. `ORDER BY`
8. `OFFSET` / `FETCH` / `TOP` / `LIMIT`

Hệ quả bắt buộc:

- `WHERE` **không** thấy alias của `SELECT`.
- `HAVING` thấy aggregate; `WHERE` không — lọc hàng *trước* gộp thì `WHERE`, lọc *nhóm* thì `HAVING`.
- Window tính **sau** `GROUP BY`/`HAVING`, **trước** `DISTINCT` ngoài cùng.
- `ORDER BY` được dùng alias `SELECT` (cả hai). `GROUP BY` thì không (trừ lặp lại biểu thức, hoặc `GROUP BY ALL` trên PG 19 — mục 6.3).

```sql
SELECT year_num AS y
FROM sales
WHERE y = 2026;              -- lỗi: y chưa tồn tại

SELECT year_num AS y
FROM sales
ORDER BY y;                  -- OK

SELECT customer_id, SUM(total) AS revenue
FROM orders
WHERE SUM(total) > 1000      -- lỗi: aggregate không ở WHERE
GROUP BY customer_id;
```

### 3.2 Alias, HAVING, window

Lọc theo `ROW_NUMBER` không đặt trong `WHERE` cùng mức — window chưa tồn tại:

```sql
-- Sai
SELECT *, ROW_NUMBER() OVER (ORDER BY id) AS rn
FROM orders
WHERE rn = 1;

-- Đúng: CTE / derived table
WITH ranked AS (
    SELECT *, ROW_NUMBER() OVER (ORDER BY id) AS rn
    FROM orders
)
SELECT * FROM ranked WHERE rn = 1;
```

`HAVING` sau `GROUP BY`: predicate trên nhóm. `WHERE` trước: giảm số hàng vào aggregate — thường rẻ hơn. `HAVING COUNT(*) FILTER (WHERE status = 'paid')` (PostgreSQL) vẫn là lọc nhóm, không thay `WHERE` trên bảng gốc.

### 3.3 DISTINCT so với LIMIT

`DISTINCT` nằm trong bước `SELECT` (sau window). `LIMIT`/`FETCH` cắt *sau* `ORDER BY`. Kết hợp `DISTINCT` + `ORDER BY` cột không có trong list → SQL Server lỗi; PostgreSQL chỉ cho `ORDER BY` cột/alias nằm trong kết quả `DISTINCT` (hoặc biểu thức phụ thuộc).

```sql
-- SQL Server: lỗi — OrderDate không có trong DISTINCT list
SELECT DISTINCT CustomerId
FROM dbo.Orders
ORDER BY OrderDate;

-- PostgreSQL: cũng lỗi cùng lý do (ORDER BY phải nằm trong kết quả DISTINCT)
```

**Ghi chú:** Optimizer có thể vừa `WHERE` vừa join. Logical order vẫn là công cụ debug đúng/sai kết quả; plan là công cụ debug đúng/sai chi phí. `EXPLAIN` (PG) / actual plan (SSMS) không thay thế bước 3.1 khi tranh cãi “sao mất hàng”. IQP (mục 14) chỉ đổi plan, không cho phép `WHERE alias`.

---

## 4. FROM & table source

```sql
FROM dbo.Orders AS o
FROM orders o
FROM (SELECT 1 AS x) AS t          -- derived: SQL Server bắt buộc alias
FROM dbo.tvf(1) AS f               -- SQL Server TVF
FROM generate_series(1, 10) AS g(n)
```

**VALUES** — bảng hằng, hữu ích staging nhỏ / probe:

```sql
SELECT *
FROM (VALUES (1, 'a'), (2, 'b')) AS v(id, name);
```

`APPLY` / `LATERAL` — table source phụ thuộc hàng trái: [joins.md](joins.md) §8. `GRAPH_TABLE` là table source (mục 11), không phải hàm vô hướng. `TABLESAMPLE` gắn *một* table source (mục 12), không gắn lên kết quả join.

Nhiều nguồn không `JOIN` tường minh (`FROM a, b WHERE …`) = tích Descartes rồi lọc — dễ quên `WHERE` thành cross join. Viết `INNER JOIN … ON`.

**Ghi chú:** PostgreSQL `FROM func(x)` khi `x` là cột bảng trái **cần** `LATERAL`. SQL Server TVF tương quan dùng `CROSS APPLY` / `OUTER APPLY`, không viết `JOIN dbo.tvf(o.id)` kiểu độc lập. Derived table SQL Server **bắt buộc** alias; PostgreSQL cũng nên đặt alias (một số ngữ cảnh bắt buộc).

---

## 5. WHERE & sargable

```sql
WHERE status = 'paid'
  AND created_at >= DATE '2026-01-01'
  AND deleted_at IS NULL;
```

`WHERE` loại hàng mà predicate ≠ `TRUE` — kể cả `UNKNOWN` (`NULL = 1`, `NULL <> 1`). `IN (NULL)` không bao giờ `TRUE`.

**Sargable** (search-argument-able): so sánh **cột gốc** (hoặc biểu thức đã index) với hằng / tham số, để seek/range scan. Bọc cột trong hàm, tính toán, hoặc implicit convert lệch kiểu → scan.

```sql
-- Xấu: hàm trên cột
WHERE YEAR(created_at) = 2026                          -- SQL Server
WHERE date_trunc('year', created_at) = TIMESTAMPTZ '2026-01-01'  -- PG

-- Tốt: khoảng nửa-mở (ổn định timezone / datetime)
WHERE created_at >= '2026-01-01'
  AND created_at <  '2027-01-01'
```

Thêm mẫu:

```sql
-- LIKE: tiền tố sargable; chứa giữa thì không
WHERE sku LIKE 'ABC%'            -- có thể seek
WHERE sku LIKE '%ABC%'           -- scan / trigram (PG GIN) — indexes.md

-- Implicit convert: nvarchar vs varchar, int vs decimal
WHERE varchar_col = N'x'         -- SQL Server: convert cột → mất index
WHERE id = '42'                  -- lệch kiểu; viết đúng literal/tham số

-- OR hai cột khác nhau: thường Union / scan, không một seek
WHERE email = @e OR phone = @p

-- Tham số tùy chọn — sniffing / OPPO (mục 14.3)
WHERE (@status IS NULL OR status = @status)
```

Cột computed `PERSISTED` (SQL Server) / `STORED` hoặc expression index (PostgreSQL) là lối thoát khi *phải* predicate theo hàm — [indexes.md](indexes.md), [ddl.md](ddl.md).

`CAST` / biểu thức trên cột trong `WHERE` vừa mất sargable vừa làm **CE** (cardinality estimate) lệch — SQL Server 2025 có CE feedback cho *expression* (mục 14.2), vẫn không thay cột gốc + khoảng.

**Ghi chú:** `IS NULL` / `IS NOT NULL` có thể dùng index. `<>` / `NOT` thường kém hơn range affirmative. Collation khác nhau hai phía so sánh → không seek. Parameter sniffing (SQL Server) và `work_mem` (PG) ảnh hưởng plan, không đổi sargable.

---

## 6. GROUP BY, HAVING, CUBE

```sql
SELECT customer_id, SUM(total) AS revenue
FROM orders
WHERE status = 'paid'
GROUP BY customer_id
HAVING SUM(total) > 1000;
```

### 6.1 Functional dependency

**SQL Server:** mọi cột trong `SELECT` không nằm trong aggregate **phải** có trong `GROUP BY`. Không suy functional dependency từ PK.

**PostgreSQL:** nếu `GROUP BY` khóa chính của bảng, cột khác của *cùng bảng* được chọn (SQL:2003 functional dependency).

```sql
-- PostgreSQL OK nếu customers.id là PK
SELECT c.id, c.name, COUNT(*)
FROM customers c
JOIN orders o ON o.customer_id = c.id
GROUP BY c.id;

-- SQL Server: GROUP BY c.id, c.name  (hoặc MAX(c.name) — vô nghĩa nếu PK)
```

PG 19: `GROUP BY` xử lý subquery trong target list tham chiếu cột ngoài subquery **ổn định hơn** (tránh kế hoạch/lỗi góc). Vẫn không được chọn cột không phụ thuộc nhóm trên SQL Server.

### 6.2 GROUPING SETS / CUBE / ROLLUP

`GROUPING SETS` / `CUBE` / `ROLLUP` — cả hai:

```sql
SELECT country, city, SUM(total) AS revenue
FROM orders
GROUP BY GROUPING SETS ((country), (country, city), ());

GROUP BY ROLLUP (country, city);     -- (country,city), (country), ()
GROUP BY CUBE (country, city);       -- mọi tập con
```

`GROUPING(col)` = 1 khi `NULL` là *siêu tổng* rollup, 0 khi `NULL` là giá trị thật. SQL Server thêm `GROUPING_ID(...)` (bitmask). PostgreSQL: `GROUPING(a, b)` cũng trả bitmask.

```sql
SELECT
    country,
    GROUPING(country) AS is_grand,
    SUM(total)
FROM orders
GROUP BY ROLLUP (country);
```

**Ghi chú:** `COUNT(*)` đếm hàng nhóm; `COUNT(col)` bỏ `NULL`. `SUM` trên tập rỗng không có nhóm → 0 hàng, không phải `0` — khác `COALESCE((SELECT SUM…), 0)` scalar. Join 1-n trước `GROUP BY` nhân hàng — fan-out: [joins.md](joins.md) §11. PG 19 có thể **aggregate trước join** khi rewrite có lợi — cùng kết quả logic, plan khác; không miễn khai fan-out trong SQL viết tay.

### 6.3 GROUP BY ALL (PostgreSQL 19)

PostgreSQL **19** (**beta**): `GROUP BY ALL` = mọi cột non-aggregate / non-window trên `SELECT` list. Không có trên SQL Server 2025.

```sql
SELECT customer_id, status, COUNT(*) AS n, SUM(total) AS revenue
FROM orders
GROUP BY ALL;
-- ≡ GROUP BY customer_id, status
```

Tiện khi list dài, **nguy hiểm** khi ai đó thêm cột vào `SELECT`: grouping đổi **im lặng**, cardinality báo cáo đổi, index/hash agg khác.

```sql
-- Review: thêm o.created_at vào list = nhóm theo ngày, không còn theo khách+status
SELECT customer_id, status, o.created_at, COUNT(*)
FROM orders AS o
GROUP BY ALL;
```

Không kết hợp mơ hồ với `GROUPING SETS`/`CUBE` như “ALL cộng ROLLUP” — viết `GROUP BY ALL` **hoặc** `GROUPING SETS` tường minh. Window trong list không vào grouping (cùng quy tắc cột aggregate).

SQL Server tương đương: liệt kê cột, hoặc gộp bằng CTE rồi `GROUP BY` tường minh. Port `GROUP BY ALL` sang T-SQL = viết lại list.

**Ghi chú:** Đổi `SELECT` = đổi `GROUP BY`. PR thêm cột “cho UI” vào query `GROUP BY ALL` là đổi ngữ nghĩa. Functional dependency PK vẫn áp khi `GROUP BY ALL` suy ra đủ khóa — đừng dựa vào đó khi port sang SS.

---

## 7. SELECT list

```sql
SELECT
    o.id,
    o.total * 1.1 AS with_tax,
    (SELECT MAX(paid_at) FROM payments p WHERE p.order_id = o.id) AS last_paid
FROM orders o;
```

Scalar subquery: 0 hàng → `NULL`; >1 hàng → lỗi runtime. Nhiều hàng: `APPLY`/`LATERAL` hoặc aggregate. Xem [cte-subqueries.md](cte-subqueries.md).

`SELECT *` rồi “trừ cột”: **không** có `SELECT * EXCEPT` trên SQL Server 2025 hay PostgreSQL 19. Liệt kê cột, view, hoặc (PG) JSON rồi bỏ key — không portable.

Alias trong *cùng* list: không dùng lại `with_tax` ở cột kế (trừ vài chỗ T-SQL không portable). Lặp biểu thức hoặc CTE.

`SELECT *` trong view bind lúc `CREATE` — thêm cột bảng gốc **không** tự xuất hiện: [ddl.md](ddl.md).

**Ghi chú:** `DISTINCT` + cột TEXT/BLOB lớn = sort/hash đắt. Chỉ `DISTINCT` cột cần uniqueness, hoặc `GROUP BY`. Vector search trong `SELECT` (`VECTOR_SEARCH`, SQL Server **PREVIEW**; `pgvector` extension, không core PG 19) không phải toán tử `SELECT` thường — [typesystem.md](typesystem.md).

---

## 8. ORDER BY, FETCH vs TOP vs LIMIT

Không `ORDER BY` ⇒ thứ tự **không xác định** giữa các lần chạy, sau vacuum/rebuild, song song. `LIMIT 10` không `ORDER BY` là “10 hàng nào đó”.

```sql
-- Chuẩn (cả hai) — SQL:2008
ORDER BY total DESC, id DESC
OFFSET 20 ROWS FETCH NEXT 10 ROWS ONLY;
```

| | SQL Server 2025 | PostgreSQL 19 |
|---|---|---|
| Cú pháp riêng | `TOP (n) [PERCENT] [WITH TIES]` | `LIMIT n OFFSET m` |
| `WITH TIES` | Chỉ với `TOP`, cần `ORDER BY` | `FETCH FIRST n ROWS WITH TIES` |
| `OFFSET`/`FETCH` | Bắt buộc `ORDER BY` | `ORDER BY` không bắt buộc (nhưng cần nếu muốn ổn định) |
| Kết hợp | **Không** `TOP` + `OFFSET`/`FETCH` | `LIMIT` ≡ `FETCH FIRST` |
| Offset lớn | Scan + skip; đắt | Đắt; planner không biến offset thành seek |
| `PERCENT` | `TOP (n) PERCENT` | không trên `LIMIT`/`FETCH` |

PostgreSQL chấp nhận cả ba dạng cắt: `LIMIT`, `FETCH FIRST n ROWS ONLY`, `FETCH FIRST n ROWS WITH TIES`. `LIMIT ALL` = không cắt. `OFFSET` không `LIMIT` = bỏ n hàng rồi trả phần còn.

```sql
-- PostgreSQL: hai câu tương đương (không TIES)
SELECT * FROM orders ORDER BY id
FETCH FIRST 20 ROWS ONLY;

SELECT * FROM orders ORDER BY id
LIMIT 20;
```

### 8.1 WITH TIES và PERCENT

`WITH TIES`: giữ thêm hàng **hòa** khóa `ORDER BY` với hàng cuối trang. Không có khóa độc nhất → trang “10” có thể 10+k hàng.

```sql
-- Năm đơn cùng total = 100 đứng hạng 10–14: FETCH 10 WITH TIES trả 14 hàng
SELECT id, total
FROM orders
ORDER BY total DESC
FETCH FIRST 10 ROWS WITH TIES;     -- PostgreSQL

SELECT TOP (10) WITH TIES id, total
FROM dbo.Orders
ORDER BY total DESC;               -- SQL Server
```

API phân trang **không** dùng `WITH TIES` trừ khi hợp đồng “top 10 kể cả hòa”. Thêm `id` vào `ORDER BY` để cắt cứng.

`TOP (10) PERCENT`: cắt theo phần trăm **sau sort** — SQL Server. 1000 hàng → ~100. Làm tròn theo engine; không portable. PostgreSQL: tự tính `CEIL(COUNT(*) * 0.1)` rồi `LIMIT` — hai statement hoặc window `NTILE`/`CUME_DIST`, không có `PERCENT` trên `LIMIT`.

### 8.2 OFFSET sâu

`OFFSET 100000` = đọc (và thường sort) rồi **bỏ** 100000 hàng. Không seek tới “hàng 100001”. Index `ORDER BY` giúp sort rẻ / tránh sort tường minh, **không** biến offset thành key lookup của trang N.

Hệ quả:

- Trang càng sâu càng chậm — O(offset + limit) về I/O logic.
- Insert/delete đồng thời: offset **trùng hoặc nhảy hàng** giữa hai request.
- `OFFSET` + `WITH TIES` càng khó đoán số hàng.

Phân trang API: keyset (mục 9), không `page * page_size`. Cột `ORDER BY` nên khớp index trái-sang-phải; `DESC` cần index `DESC` hoặc scan ngược (cả hai hỗ trợ).

**Ghi chú:** SQL Server `OFFSET`/`FETCH` **đòi** `ORDER BY`; thiếu = lỗi parse. PostgreSQL cho `LIMIT` không `ORDER BY` — hợp lệ và **không ổn định**. Cursor server-side (`DECLARE CURSOR`, keyset/static SS) không thay HTTP pagination — mục 9.

---

## 9. Keyset pagination

Keyset (seek): “hàng sau khóa đã thấy”, không skip N. Cần **sort key độc nhất** (thêm `id` nếu `created_at` trùng).

```sql
-- PostgreSQL: so sánh tuple native (lexicographic)
SELECT id, created_at, total
FROM orders
WHERE (created_at, id) < (@ts, @id)
ORDER BY created_at DESC, id DESC
FETCH NEXT 20 ROWS ONLY;
```

SQL Server **không** so sánh `(a, b) < (@a, @b)` như PostgreSQL. Viết tay, giữ sargable:

```sql
-- SQL Server: dạng seek được
WHERE created_at < @ts
   OR (created_at = @ts AND id < @id)
ORDER BY created_at DESC, id DESC
OFFSET 0 ROWS FETCH NEXT 20 ROWS ONLY;
```

Hướng `ASC` đảo bất đẳng thức. Composite 3 cột: mở từng prefix (`a < @a OR (a = @a AND (b < @b OR …))`).

Giới hạn:

- Không nhảy tới “trang 17” mà không có key trang 16 (hoặc bảng key đã materialize).
- `NULL` trong khóa: so sánh tuple/`OR` với `NULL` → `UNKNOWN` → mất hàng. `ORDER BY created_at DESC NULLS LAST` (PG) phải khớp predicate; SQL Server `NULL` sort khác — thống nhất `COALESCE` hoặc `WHERE created_at IS NOT NULL`.
- Insert đồng thời: keyset **ổn định hơn** offset (không skip/duplicate vì hàng mới đẩy offset), vẫn cần khóa độc nhất.

**Ghi chú:** Cursor `KEYSET`/`STATIC` (SQL Server) và `DECLARE CURSOR` (PG) là API khác — không dùng cho HTTP pagination. Keyset là `WHERE` + `ORDER BY` + `FETCH`.

---

## 10. DISTINCT & DISTINCT ON vs ROW_NUMBER

```sql
SELECT DISTINCT customer_id FROM orders;
```

`DISTINCT` hash/sort toàn hàng kết quả. Nhiều cột TEXT → đắt; thường `GROUP BY` khóa nghiệp vụ rõ hơn.

**PostgreSQL `DISTINCT ON`:** một hàng “đại diện” mỗi bộ khóa, hàng nào do `ORDER BY` quyết định. Cột `DISTINCT ON` **phải là prefix** của `ORDER BY`:

```sql
SELECT DISTINCT ON (customer_id) *
FROM orders
ORDER BY customer_id, created_at DESC, id DESC;
-- → đơn mới nhất mỗi khách
```

SQL Server **không** có `DISTINCT ON`. Tương đương chuẩn (cả hai):

```sql
WITH ranked AS (
    SELECT o.*,
           ROW_NUMBER() OVER (
               PARTITION BY customer_id
               ORDER BY created_at DESC, id DESC
           ) AS rn
    FROM orders AS o
)
SELECT *    -- liệt kê cột, bỏ rn
FROM ranked
WHERE rn = 1;
```

`QUALIFY` không có trên hai engine này. Lọc window bằng CTE — [window-functions.md](window-functions.md).

`OUTER APPLY (SELECT TOP (1) … ORDER BY …)` (SQL Server) / `LEFT JOIN LATERAL (… LIMIT 1)` (PG) tương đương “lấy 1 con mới nhất” và đôi khi plan tốt hơn `ROW_NUMBER` trên toàn bảng khi có index `(customer_id, created_at DESC)`.

**Ghi chú:** `DISTINCT ON` không portable. API công khai / ORM: `ROW_NUMBER` hoặc `LATERAL`. `GROUP BY customer_id` + `MAX(created_at)` **không** lấy cả hàng (chỉ lấy max) — join lại theo `(customer_id, created_at)` vẫn vỡ nếu timestamp trùng; thêm `id`.

---

## 11. GRAPH_TABLE (PostgreSQL 19)

SQL/PGQ: property graph là **metadata** trên bảng quan hệ (vertex/edge), không phải storage riêng. `GRAPH_TABLE` trả về bảng, đứng trong `FROM` như table function. Planner **rewrite thành join thường** — `EXPLAIN` không có executor graph riêng. Index PK/FK vẫn bắt buộc. DDL tạo graph: [ddl.md](ddl.md) §11.

PostgreSQL 19 **beta**: đối chiếu release notes trước production.

### 11.1 Metadata, không storage riêng

Bảng vertex/edge **đã có**. `CREATE PROPERTY GRAPH` gắn label, hướng cạnh, khóa. `DROP PROPERTY GRAPH` **không** drop bảng.

```sql
CREATE PROPERTY GRAPH shop
    VERTEX TABLES (
        customers LABEL customer PROPERTIES (id, name),
        orders    LABEL "order"    PROPERTIES (id, ordered_when, total)
    )
    EDGE TABLES (
        customer_orders
            SOURCE customers
            DESTINATION orders
            LABEL has_placed
    );
```

Cần PK/FK hoặc `KEY` / `SOURCE KEY` / `DESTINATION KEY` tường minh khi tên cột không suy ra được. Label `"order"` **quote** vì reserved. Quyền: `USAGE` trên graph vs `SELECT` trên bảng gốc — đọc GRANT docs 19, đừng bịa grant riêng.

Không có cột ẩn “graph id”. Không có file/AM graph. Cạnh = hàng bảng edge.

### 11.2 MATCH một hop và nhiều hop cố định

```sql
SELECT customer_name, order_id
FROM GRAPH_TABLE (
    shop
    MATCH (c IS customers)
          -[IS customer_orders]->
          (o IS orders WHERE o.ordered_when = CURRENT_DATE)
    COLUMNS (c.name AS customer_name, o.id AS order_id)
) AS g;
```

`WHERE` **trong** pattern (vertex/edge) lọc trước khi chiếu `COLUMNS`. `WHERE` **ngoài** `GRAPH_TABLE` lọc result set như derived table:

```sql
SELECT g.customer_name, g.order_id, g.total
FROM GRAPH_TABLE (
    shop
    MATCH (c IS customers)-[IS customer_orders]->(o IS orders)
    COLUMNS (c.name AS customer_name, o.id AS order_id, o.total)
) AS g
WHERE g.total > 100;
```

Hai hop cố định (khách → đơn → item) — **được** vì độ dài path hằng:

```sql
SELECT customer_name, sku
FROM GRAPH_TABLE (
    shop
    MATCH (c IS customers)
          -[IS customer_orders]->
          (o IS orders)
          -[IS order_has_item]->
          (i IS items)
    COLUMNS (c.name AS customer_name, i.sku)
) AS g;
```

(Giả sử graph đã khai báo edge `order_has_item` và vertex `items` — [ddl.md](ddl.md).)

`GRAPH_TABLE` join tiếp bảng thường:

```sql
SELECT g.customer_name, r.region
FROM GRAPH_TABLE (
    shop
    MATCH (c IS customers)-[IS customer_orders]->(o IS orders)
    COLUMNS (c.id AS customer_id, c.name AS customer_name)
) AS g
JOIN regions AS r ON r.customer_id = g.customer_id;
```

### 11.3 Rewrite thành join — EXPLAIN

Pattern một hop `(c)-[e]->(o)` tương đương *ý*:

```sql
SELECT c.name AS customer_name, o.id AS order_id
FROM customers AS c
JOIN customer_orders AS e ON e.customer_id = c.id   -- SOURCE KEY
JOIN orders AS o ON o.id = e.order_id               -- DESTINATION KEY
WHERE o.ordered_when = CURRENT_DATE;
```

`EXPLAIN` / `EXPLAIN (ANALYZE, BUFFERS)` hiện `Nested Loop` / `Hash Join` / `Seq Scan` — **không** node “Graph”. Thiếu index FK = nested loop nặng **như** join thủ công. Selective graph không miễn thống kê cũ.

Không có lock mode riêng cho graph. `FOR UPDATE` trên `SELECT` bọc `GRAPH_TABLE`: khóa bảng gốc trong rewrite — đọc docs 19 hiện tại; thu hẹp `WHERE` như join thường. [concurrency.md](concurrency.md).

### 11.4 Giới hạn 19 (chưa có)

**Chưa có trên PG 19:**

| Kỳ vọng SQL/PGQ đầy đủ | 19 |
|---|---|
| Path biến độ dài `{1,4}` / `+` / `*` | **không** |
| Shortest / cheapest path | **không** |
| Path variable đầy đủ (giữ nguyên path object) | **không** |
| Quantified path + filter trên path | **không** |

Path cố định (hai-ba hop) hoặc **recursive CTE** — [cte-subqueries.md](cte-subqueries.md). Đừng viết cú pháp SQL/PGQ đầy đủ rồi mong 19 chạy.

Tương đương “mọi đơn trong 1–3 hop” = CTE đệ quy trên bảng edge, không `MATCH …{1,3}`.

```sql
-- Recursive CTE trên cạnh — portable ý, không phải PGQ
WITH RECURSIVE walk AS (
    SELECT customer_id, order_id, 1 AS hop
    FROM customer_orders
    UNION ALL
    SELECT w.customer_id, e.order_id, w.hop + 1
    FROM walk AS w
    JOIN customer_orders AS e ON e.customer_id = w.order_id  -- minh họa; schema thật khác
    WHERE w.hop < 3
)
SELECT * FROM walk;
```

(Cạnh thật phải khớp schema; đây là *hướng* thay `{1,3}`, không phải API graph.)

### 11.5 SQL Server MATCH ≠ SQL/PGQ

SQL Server **không** có `GRAPH_TABLE` / `CREATE PROPERTY GRAPH`. Graph cũ (`AS NODE` / `AS EDGE`, `MATCH (a)-(e)->(b)`) vẫn tồn tại nhưng **không** phải hướng chính 2025 (vector / relational) và **không** cùng chuẩn SQL/PGQ. Đừng port PGQ sang T-SQL `MATCH` và ngược lại.

Hybrid search 2025 = vector + full-text, không phải property graph.

**Ghi chú:** `GRAPH_TABLE` vẫn là `SELECT` — aggregation, `JOIN`, `WHERE` ngoài được. Beta: cú pháp `PROPERTIES` / `LABEL` có thể chỉnh trước GA. Không invent `SHORTEST` / `CHEAPEST` / `PATH`. Selective + thiếu index = chậm như join.

---

## 12. TABLESAMPLE

Lấy mẫu **vật lý** — thống kê / probe, **không** random row chuẩn xác theo xác suất hàng (trừ Bernoulli). Không dùng sample cho quyết định tài chính.

```sql
-- PostgreSQL: SYSTEM (theo page) hoặc BERNOULLI (theo hàng)
SELECT * FROM orders TABLESAMPLE SYSTEM (1);
SELECT * FROM orders TABLESAMPLE BERNOULLI (1) REPEATABLE (42);

-- SQL Server: chỉ SYSTEM (page); REPEATABLE (seed) có
SELECT TOP (100) *          -- không: TOP không biến sample thành đúng n hàng ngẫu nhiên
FROM dbo.Orders TABLESAMPLE (1 PERCENT) REPEATABLE (42);

SELECT * FROM dbo.Orders TABLESAMPLE (1000 ROWS);
```

| | `SYSTEM` | `BERNOULLI` |
|---|---|---|
| Đơn vị | Page / block | Từng hàng |
| Tốc độ | Nhanh (bỏ cả page) | Chậm hơn (nhìn mọi hàng) |
| Lệch | Lớn nếu hàng/page không đều (TOAST, fillfactor, clustering) | Gần xác suất p mỗi hàng |
| SQL Server | Có (`PERCENT` hoặc `ROWS`) | **Không** |
| PostgreSQL | Có | Có |

`SYSTEM (1)` ≈ “lấy ~1% **page**”, không “đúng 1% hàng”. Bảng 100 page, một page đầy hàng lớn → mẫu lệch. `BERNOULLI (1)` mỗi hàng xác suất 1% — kỳ vọng 1% hàng, phương sai Binomial, **không** đúng n hàng.

`REPEATABLE (seed)`: cùng seed + cùng snapshot vật lý → cùng mẫu. Vacuum / `REPACK` / rebuild đổi page → seed cũ **không** tái lập. Dùng cho A/B test nội bộ, không phải khóa audit.

`TABLESAMPLE (1000 ROWS)` (SQL Server): mục tiêu ~1000 hàng qua ước lượng page — **không** guarantee đúng 1000. Cần đúng n: `ORDER BY NEWID()` / `TABLESAMPLE` rồi `TOP` — đắt và lệch.

Kết hợp `WHERE` **sau** sample ≠ “1% hàng thỏa predicate”:

```sql
-- ~1% page, *rồi* lọc paid — tỷ lệ paid trong mẫu ≠ 1% đơn paid
SELECT *
FROM orders TABLESAMPLE SYSTEM (1)
WHERE status = 'paid';
```

Muốn ~1% hàng *đã* `paid`: lọc trong derived table **không** được `TABLESAMPLE` trên kết quả join/`WHERE` như toán tử xác suất hàng. Lấy mẫu từ partition/index-only: đọc docs từng engine — `TABLESAMPLE` áp trên *storage scan của bảng đó*.

View phức tạp / partitioned: sample từng partition leaf tùy engine; không giả định “1% toàn bảng logic”.

Không thay `ORDER BY random() LIMIT n` / `TABLESAMPLE` + `ORDER BY NEWID() TOP n` khi cần đúng n hàng (và đắt). `random()` sort toàn bộ.

**Ghi chú:** `TABLESAMPLE` không đi qua index seek có nghĩa “mẫu theo khóa”. `REPEATABLE` không khóa isolation. Kết hợp `FOR UPDATE` + sample = khóa tập page ngẫu nhiên — hầu như vô nghĩa cho queue.

---

## 13. FOR UPDATE — con trỏ khóa

`SELECT` mặc định **không** giữ khóa ghi. Read-modify-write: khóa tường minh. Chi tiết mode, `SKIP LOCKED`, deadlock: [concurrency.md](concurrency.md). Isolation: [transactions.md](transactions.md).

```sql
-- PostgreSQL
SELECT * FROM orders WHERE id = 1 FOR UPDATE;
SELECT * FROM orders WHERE id = 1 FOR UPDATE SKIP LOCKED;
SELECT * FROM orders WHERE id = 1 FOR UPDATE NOWAIT;
SELECT * FROM orders WHERE id = 1 FOR NO KEY UPDATE;   -- không chặn INSERT FK vào hàng này
SELECT * FROM orders WHERE id = 1 FOR SHARE;

-- SQL Server
SELECT * FROM dbo.Orders WITH (UPDLOCK, ROWLOCK) WHERE Id = 1;
SELECT * FROM dbo.Orders WITH (UPDLOCK, ROWLOCK, HOLDLOCK) WHERE Id = 1;
SELECT * FROM dbo.Queue WITH (UPDLOCK, ROWLOCK, READPAST) WHERE …;
```

`FOR UPDATE` PostgreSQL gắn **cuối** `SELECT` (sau `FOR UPDATE OF bảng` / `LIMIT`). Không viết giữa `FROM` và `WHERE`. SQL Server hint trên table source.

**Ghi chú:** `FOR UPDATE` trên `SELECT` không `WHERE` khóa mọi hàng nhìn thấy — tai nạn. Kết hợp `LIMIT` + `SKIP LOCKED` cho queue worker. `NOLOCK` / `READ UNCOMMITTED` không phải bản SQL Server của `FOR UPDATE`. Optimized locking 2025 **không** thay `UPDLOCK`.

---

## 14. Plan SELECT: IQP 2025 & PG 19

Logical processing (mục 3) **không** đổi. Compat SQL Server **170** + Query Store đổi **cách chọn plan** cho cùng câu `SELECT`. Nâng *engine* ≠ nâng *compat*: giữ 160 đo regression rồi mới 170. Kiến trúc optimizer: [internal.md](internal.md) §13. Join/anti rewrite PG: [joins.md](joins.md) §10.

### 14.1 DOP feedback

SQL Server 2025: **Degree of Parallelism feedback ON mặc định**. Query `SELECT` song song quá đà (CXPACKET, tempdb spill) hoặc quá ít được điều chỉnh qua lần chạy sau (Query Store). Không sửa `WHERE` sai; không thay index thiếu.

Hệ quả review:

- Cùng câu, lần 1 `MAXDOP` 8, lần sau có thể khác — nhìn Query Store, không chỉ plan “hôm qua”.
- `OPTION (MAXDOP n)` vẫn ghi đè.
- Báo cáo nặng trên replica: QS secondary **ON mặc định** (14.4) — DOP feedback theo *workload replica*.

PostgreSQL: `max_parallel_workers_per_gather`, không có “DOP feedback” kiểu IQP. `EXPLAIN (ANALYZE)` + `BUFFERS` / `IO` (19). JIT **tắt mặc định 19** — analytical `SELECT` lớn có thể chậm hơn 18 nếu quên `jit = on`.

### 14.2 CE feedback trên biểu thức

Cardinality estimate sai khi `WHERE` có `CAST`, computed, `YEAR(col)`, biểu thức. 2025: CE feedback cho **expression** — nhớ ước lượng lệch, chỉnh lần sau.

Vẫn: viết sargable (mục 5) hơn là chờ feedback. `CAST(varchar_col AS int) = @id` vừa scan vừa CE tệ.

```sql
-- CE khó: biểu thức hai phía
WHERE DATEADD(day, 1, created_at) >= @d          -- SQL Server
WHERE created_at + INTERVAL '1 day' >= @d        -- PG — vẫn khó seek

-- CE dễ hơn: cột gốc
WHERE created_at >= DATEADD(day, -1, @d)
```

### 14.3 OPPO / PSPO — tham số tùy chọn

Mẫu kinh điển sniffing:

```sql
-- SQL Server: @status NULL = “mọi status”
SELECT *
FROM dbo.Orders
WHERE (@status IS NULL OR status = @status)
  AND created_at >= @from;
```

Plan cache một plan (seek `status` **hoặc** scan). **OPPO** (optional parameter plan optimization, 2025) dùng hạ tầng **PSPO** (parameter-sensitive plan): có thể **nhiều plan** theo tính chất tham số. Đo plan cache sau compat 170 — số plan tăng.

Không thay:

- Dynamic SQL / `IF @status IS NULL` hai câu.
- `OPTION (RECOMPILE)` (CPU compile).
- Filtered index + sniff `NULL`.

PostgreSQL: generic vs custom plan (`plan_cache_mode`). `pg_plan_advice` / `pg_stash_advice` (**19**, contrib) ghim theo query id — [joins.md](joins.md) §10. Không bật mù như hint SS.

`ABORT_QUERY_EXECUTION`: hint / Query Store chặn `SELECT` đã biết độc — không phải lock hint, không thay Resource Governor.

### 14.4 Query Store secondary

Readable secondary 2025: Query Store **ON mặc định** + **persisted statistics** trên replica. `SELECT` báo cáo trên AG secondary có plan/stats **riêng**, I/O ghi thêm trên replica. Đo CPU/disk replica sau upgrade, không giả định “đọc thuần”.

PostgreSQL hot standby: plan theo GUC/stats replica; `WAIT FOR` LSN là *đồng bộ WAL*, không phải Query Store — [transactions.md](transactions.md), [internal.md](internal.md) §15.

**Ghi chú:** IQP “không sửa code” vẫn đổi plan. Baseline Query Store **trước** 160→170. OPPO/PSPO không sửa `NOT IN (NULL)`. Feedback không thay `TABLESAMPLE` lệch.

---

## 15. Worked examples

### 15.1 Đơn giản — doanh thu khách đã thanh toán

```sql
SELECT customer_id, SUM(total) AS revenue
FROM orders
WHERE status = 'paid'
  AND created_at >= DATE '2026-01-01'
  AND created_at <  DATE '2027-01-01'
GROUP BY customer_id
HAVING SUM(total) > 1000
ORDER BY revenue DESC
FETCH NEXT 50 ROWS ONLY;
```

Predicate khoảng trên `created_at` (sargable). `HAVING` sau gộp. `FETCH` có `ORDER BY`.

### 15.2 Trung bình — một đơn mới nhất mỗi khách

`DISTINCT ON (customer_id) … ORDER BY customer_id, created_at DESC, id DESC` (PostgreSQL) hoặc CTE `ROW_NUMBER()` portable — cú pháp đủ ở mục 10. Index `(customer_id, created_at DESC, id DESC)` cho `LATERAL`/`APPLY` `LIMIT 1`/`TOP (1)` khi chỉ cần vài khách, không sort cả bảng.

`GROUP BY ALL` cùng ý *không* lấy “đơn mới nhất”: chỉ nhóm, không chọn hàng đại diện.

### 15.3 Nâng cao — keyset + CUBE + không fan-out

Trang tiếp theo (keyset) *sau khi* đã gộp theo quốc gia/thành phố, không join `payments` thô (sẽ nhân `SUM`):

```sql
WITH paid AS (
    SELECT country, city, SUM(total) AS revenue
    FROM orders
    WHERE status = 'paid'
    GROUP BY GROUPING SETS ((country, city), (country), ())
),
page AS (
    SELECT country, city, revenue, GROUPING(country, city) AS g
    FROM paid
    WHERE (GROUPING(country, city), country, city) > (@g, @country, @city)  -- PG tuple
    ORDER BY g, country, city
    FETCH NEXT 20 ROWS ONLY
)
SELECT * FROM page;
```

SQL Server: thay so sánh tuple bằng `OR` prefix (mục 9); `GROUPING_ID(country, city)` thay `GROUPING(country, city)` nếu muốn một số nguyên.

### 15.4 GRAPH_TABLE một hop + lọc ngoài (PG 19, beta)

```sql
SELECT g.customer_name
FROM GRAPH_TABLE (
    shop
    MATCH (c IS customers)
          -[IS customer_orders]->
          (o IS orders WHERE o.status = 'paid')
    COLUMNS (c.name AS customer_name, o.total)
) AS g
WHERE g.total > 500
ORDER BY g.customer_name
FETCH FIRST 50 ROWS ONLY;
```

`EXPLAIN` phải ra join + filter, không node graph. Thiếu index `customer_orders(customer_id)` / PK `orders` = loop nặng. SQL Server: viết `INNER JOIN` tương đương, không `GRAPH_TABLE`.

### 15.5 TABLESAMPLE rồi cắt — hiểu lệch

```sql
-- Probe ~1% page, lấy tối đa 50 hàng nhìn thấy — không phải “50 hàng ngẫu nhiên đều”
SELECT id, total
FROM orders TABLESAMPLE SYSTEM (1) REPEATABLE (42)
WHERE status = 'paid'
ORDER BY id
FETCH FIRST 50 ROWS ONLY;
```

Đúng 50 hàng ngẫu nhiên (đắt): `ORDER BY random() LIMIT 50` (PG) / `TABLESAMPLE` không đủ. Báo cáo tài chính: **cấm** sample.

### 15.6 Tham số tùy chọn (SS) — ý OPPO

```sql
-- SQL Server, compat 170: OPPO/PSPO có thể nhiều plan
SELECT o.Id, o.Total, o.Status
FROM dbo.Orders AS o
WHERE (@status IS NULL OR o.Status = @status)
  AND o.CreatedAt >= @from
  AND o.CreatedAt <  @to
ORDER BY o.CreatedAt DESC, o.Id DESC
OFFSET 0 ROWS FETCH NEXT 50 ROWS ONLY;
```

Vẫn cần index `(CreatedAt, Id)` INCLUDE `Status` (hoặc ngược tùy selectivity). Không tin một plan cache cho cả `@status NULL` và `@status = 'paid'`.

---

## 16. Best practices & checklist

- Viết `ORDER BY` đầy đủ (kể cả khóa phụ) mọi lúc `TOP`/`LIMIT`/`FETCH`/phân trang.
- Sargable: khoảng ngày, không `YEAR(col)`; đúng kiểu literal/tham số.
- `WHERE` lọc hàng, `HAVING` lọc nhóm, CTE lọc window.
- Phân trang sâu: keyset, không `OFFSET` lớn.
- `DISTINCT ON` chỉ nội bộ PG; public API dùng `ROW_NUMBER` / `LATERAL`.
- `GROUP BY` PK (PG) không copy sang SQL Server. `GROUP BY ALL` (PG 19): review như đổi grouping.
- `SELECT *` không vào production query / view bền.
- Graph PG 19: path cố định + index FK; chưa variable-length; `EXPLAIN` = join.
- `TABLESAMPLE`: probe, không metric tài chính; `WHERE` sau sample ≠ mẫu theo predicate.
- Khóa khi đọc-rồi-ghi: `FOR UPDATE` / `UPDLOCK` — [concurrency.md](concurrency.md).
- Compat 170: baseline Query Store trước khi tin DOP/OPPO/CE feedback.
- `EXPLAIN` / actual plan khi nghi scan; không hint trước khi hết thống kê.

```text
□ ORDER BY độc nhất nếu cắt trang
□ Predicate sargable, kiểu khớp
□ Alias SELECT không dùng trong WHERE
□ CUBE/ROLLUP: GROUPING() phân NULL thật
□ OFFSET sâu đã bị từ chối
□ DISTINCT ON có prefix ORDER BY
□ GROUP BY ALL: list SELECT khóa grouping
□ GRAPH_TABLE: beta, không {1,4}, EXPLAIN=join
□ TABLESAMPLE không dùng cho số tiền
□ FOR UPDATE có WHERE hẹp
□ Query Store trước đổi compat 170
```

---

## 17. Bẫy khi review

- `SELECT TOP 10` / `LIMIT 10` không `ORDER BY`.
- `WHERE alias` / `WHERE ROW_NUMBER()…`.
- `WHERE o.status = 'paid'` sau `LEFT JOIN` — biến outer thành inner: [joins.md](joins.md) §6.
- `IN (SELECT nullable)` / `IN (NULL)`.
- Scalar subquery >1 hàng trên dữ liệu thật (test 1 hàng thì “pass”).
- `GROUP BY` thiếu cột trên SQL Server “sửa” bằng subquery không tương đương.
- `GROUP BY ALL` rồi thêm cột UI — đổi nhóm im lặng.
- Keyset thiếu `id` → trùng timestamp bỏ/lặp hàng.
- So sánh tuple copy sang T-SQL.
- `FETCH … WITH TIES` trên khóa không độc nhất → trang phình.
- `OFFSET` lớn coi như seek.
- `TABLESAMPLE` rồi tin là random unbiased / đúng n hàng.
- `GRAPH_TABLE` + kỳ vọng shortest path / `{1,4}` trên PG 19.
- Port PGQ sang T-SQL `MATCH` (SQL Graph cũ).
- `FOR UPDATE` trên join lớn không `OF table`.
- Tin IQP sửa sargable / `NOT IN NULL`.
- Compat 170 ngày cutover không baseline Query Store.
- Port `REPEATABLE READ` rồi tin `SELECT` ổn định giống engine kia — [transactions.md](transactions.md).

---

## 18. Version gates

| Mục | SQL Server | PostgreSQL |
|---|---|---|
| `OFFSET`/`FETCH` | 2012+ | lâu (còn `LIMIT`) |
| `FETCH … WITH TIES` | không (dùng `TOP … WITH TIES`) | 13+ (SQL) |
| `TOP … PERCENT` | có | không |
| `GROUPING SETS`/`CUBE`/`ROLLUP` | lâu | lâu |
| Functional dependency `GROUP BY` PK | không | lâu |
| `GROUP BY ALL` | không | **19 beta** |
| `GROUP BY` + subquery target (cải thiện) | — | **19** |
| `DISTINCT ON` | không | lâu |
| Tuple `(a,b) < (x,y)` | không | lâu |
| `TABLESAMPLE` | SYSTEM + `REPEATABLE` + `ROWS`/`PERCENT` | `SYSTEM`/`BERNOULLI` |
| `FOR UPDATE` / `SKIP LOCKED` | hint `UPDLOCK`/`READPAST` | `FOR UPDATE` + `SKIP LOCKED` |
| SQL/PGQ `GRAPH_TABLE` | không | **19** (**beta** đến GA) |
| Path `{n,m}` / shortest | — | **chưa** (19) |
| DOP feedback mặc định | **2025** (compat 170) | — |
| CE feedback expression | **2025** | — |
| OPPO / PSPO | **2025** | generic/custom plan; `pg_plan_advice` **19** |
| Query Store readable secondary ON | **2025** | — |
| Optimized locking (không đổi `SELECT` logic) | **2025** | — |
| Vector search trong `SELECT` | **PREVIEW** (`VECTOR_SEARCH`) | extension `pgvector` (không phải core 19) |
| JIT default off (analytical `SELECT`) | — | **19** |

Join, semi/anti, `LATERAL`: [joins.md](joins.md). Isolation khi `SELECT` lặp: [transactions.md](transactions.md). DDL graph / generated: [ddl.md](ddl.md). Optimizer engine: [internal.md](internal.md).
