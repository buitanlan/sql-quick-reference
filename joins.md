# JOIN

> **Baseline:** SQL Server **2025** (17.x) · PostgreSQL **19**.  
> Join là thao tác đại số: tích Descartes có lọc. Optimizer được đổi `INNER` thành semi/anti, đẩy predicate, reorder — **miễn kết quả logic giữ nguyên**. Plan khác nhau không có nghĩa câu sai.

Join quyết định *hàng nào tồn tại* và *hàng nào bị nhân*. Lỗi hay gặp không phải sai `INNER`/`LEFT` trên giấy, mà: (1) predicate outer đặt nhầm `WHERE`, (2) `NOT IN` với `NULL`, (3) fan-out 1-n ⋈ 1-n, (4) `NATURAL JOIN` đổi silently khi thêm cột. Hai engine cùng tên join; thuật toán và mẹo optimizer **không** portable — PostgreSQL 19 (**beta**) thêm rewrite anti/semi, aggregate-trước-join, Memoize; SQL Server 2025 thêm CE/DOP/OPPO feedback.

Khóa khi join rồi cập nhật: [concurrency.md](concurrency.md). `UPDATE … FROM` fan-out: [dml.md](dml.md). Index cho khóa join: [indexes.md](indexes.md). `EXISTS` trong CTE: [cte-subqueries.md](cte-subqueries.md). `SELECT` logical processing: [select.md](select.md) §3. Optimizer engine: [internal.md](internal.md) §13.

---

## Mục lục

- [1. Tổng quan \& triết lý](#1-tổng-quan--triết-lý)
- [2. Phân loại](#2-phân-loại)
- [3. INNER](#3-inner)
- [4. OUTER](#4-outer)
- [5. CROSS](#5-cross)
- [6. Predicate: ON vs WHERE](#6-predicate-on-vs-where)
  - [6.0 Hình dung: OUTER giữ người trái](#60-hình-dung-outer-là-giữ-người-bên-trái-dù-phải-trống)
- [7. Semi / anti \& bẫy NOT IN NULL](#7-semi--anti--bẫy-not-in-null)
  - [7.1 NOT IN + NULL](#71-not-in--null--bẫy-đầy-đủ)
  - [7.2 PG 19: ANTI JOIN rewrite](#72-pg-19-anti-join-rewrite)
- [8. APPLY vs LATERAL](#8-apply-vs-lateral)
- [9. Join algorithm](#9-join-algorithm)
- [10. Optimizer: PG 19 \& SQL Server 2025](#10-optimizer-pg-19--sql-server-2025)
  - [10.1 PostgreSQL 19](#101-postgresql-19)
  - [10.2 Memoize \& aggregate trước join](#102-memoize--aggregate-trước-join)
  - [10.3 pg\_plan\_advice](#103-pg_plan_advice)
  - [10.4 SQL Server: CE, OPPO/PSPO, DOP](#104-sql-server-ce-oppopspo-dop)
- [11. Fan-out](#11-fan-out)
- [12. NATURAL JOIN \& USING](#12-natural-join--using)
- [13. Worked examples](#13-worked-examples)
- [14. Best practices \& checklist](#14-best-practices--checklist)
- [15. Bẫy khi review](#15-bẫy-khi-review)
- [16. Version gates](#16-version-gates)

---

## 1. Tổng quan & triết lý

Join **không** phải “ghép bảng trên GUI”. Nó nhân cardinality hoặc giữ/ loại hàng không khớp. Viết `LEFT JOIN` rồi lọc phía phải ở `WHERE` là viết `INNER` mà không nhận ra. Viết hai `JOIN` 1-n vào cùng fact là nhân đo lường.

Nguyên tắc:

- **Khóa join** kiểu + collation khớp, có index phía inner (FK không tự có index — [constraints.md](constraints.md)).
- **Predicate “thuộc về quan hệ”** đặt `ON`; **predicate “lọc kết quả sau join”** đặt `WHERE`.
- **Semi/anti** khi chỉ cần tồn tại/không tồn tại — đừng `DISTINCT` sau `INNER JOIN` con.
- **Thuật toán** (loop/hash/merge) là việc optimizer; hint chỉ khi đã hết thống kê và đo.

`GRAPH_TABLE` (PG 19) cũng chỉ là join sau rewrite — [select.md](select.md) §11.

---

## 2. Phân loại

| Loại | Giữ hàng không khớp | Cardinality trái |
|---|---|---|
| `INNER` | Không | 0..n lần mỗi hàng trái |
| `LEFT` / `RIGHT` / `FULL OUTER` | Phía tương ứng / cả hai | LEFT: ≥1 (hàng trái giữ) |
| `CROSS` | Mọi cặp | \|A\| × \|B\| |
| Semi (`EXISTS` / `IN`) | — | Mỗi hàng trái **tối đa 1** |
| Anti (`NOT EXISTS`) | Hàng trái không khớp | 0 hoặc 1 |
| `CROSS APPLY` / `LATERAL` | Không (như inner) | 0..n theo hàm/bảng phải |
| `OUTER APPLY` / `LEFT JOIN LATERAL` | Có (như left) | ≥1 |

`JOIN` không từ khóa = `INNER JOIN`. `RIGHT` = `LEFT` đảo nguồn — ưu tiên `LEFT` cho dễ đọc.

Trên plan: SQL Server hiện `Left Anti Semi Join` / `Left Semi Join`. PostgreSQL 19 hiện `Anti Join` / `Semi Join` sau rewrite (mục 7.2, 10). Tên node **không** phải cú pháp viết tay.

---

## 3. INNER

```sql
SELECT o.id, c.name
FROM orders AS o
INNER JOIN customers AS c ON c.id = o.customer_id;
```

Với **INNER**, điều kiện ở `ON` hay `WHERE` **cùng kết quả** (không luôn cùng plan). Vẫn để khóa quan hệ trên `ON` cho đối xứng với outer.

Nhiều cột:

```sql
ON a.id = b.id AND a.tenant_id = b.tenant_id
```

```sql
-- PostgreSQL
USING (id, tenant_id)     -- gộp cột trùng trong SELECT *
```

`OR` trong `ON` (`a.id = b.id OR a.code = b.code`) phá hash equality — thường nested loop kém. `UNION` hai join equality thường rõ hơn.

Kiểu lệch (`int` ⋈ `bigint`, `varchar` ⋈ `nvarchar`) → implicit convert, mất index. Sửa schema hoặc convert **phía tham số/nguồn nhỏ**.

SQL Server: FK **trusted** (`is_not_trusted = 0`) cho *join elimination* — optimizer bỏ join nếu chỉ lấy cột phía cha đã bảo đảm. `NOCHECK` / disable FK → mất elimination, plan nặng hơn, *và* dữ liệu mồ côi. `WITH CHECK CHECK CONSTRAINT` sau ETL. PostgreSQL không cùng “trusted” catalog; `NOT VALID` vẫn kiểm hàng mới, planner không giả mọi hàng cũ hợp lệ cho elimination kiểu SS. [constraints.md](constraints.md), [ddl.md](ddl.md) §5.

**Ghi chú:** `FROM a, b WHERE a.id = b.id` cũ tương đương `INNER` nếu `WHERE` đủ. Thiếu điều kiện = `CROSS`. SQL Server `INNER JOIN` **bắt buộc** `ON`/`USING`; thiếu → lỗi parse, không im lặng thành cross. T-SQL **không** có `USING` — mục 12.

---

## 4. OUTER

```sql
SELECT c.id, o.id AS order_id
FROM customers AS c
LEFT JOIN orders AS o ON o.customer_id = c.id;
```

Hàng không khớp: cột phía không khớp = `NULL` (mọi cột, kể cả PK phải). `COUNT(o.id)` bỏ khách không đơn; `COUNT(*)` đếm cả khách trống.

`FULL OUTER JOIN`: giữ cả hai phía. SQL Server và PostgreSQL đều hỗ trợ.

`RIGHT JOIN` ít dùng: viết lại `LEFT` với bảng lớn/nguồn “giữ hàng” bên trái.

Outer join **không** giao hoán. `(A LEFT B) LEFT C` khác `A LEFT (B JOIN C)` — ngoặc / derived table khi chuỗi outer.

```sql
-- Khác nghĩa: C lọc trước khi outer với A, vs A left B rồi left C
SELECT …
FROM a
LEFT JOIN b ON b.a_id = a.id
LEFT JOIN c ON c.b_id = b.id AND c.active;   -- active trên ON của C

-- vs derived: chỉ b+c active, rồi left vào a
SELECT …
FROM a
LEFT JOIN (
    SELECT b.*, c.id AS c_id
    FROM b
    INNER JOIN c ON c.b_id = b.id AND c.active
) AS bc ON bc.a_id = a.id;
```

**Ghi chú:** `WHERE o.id IS NULL` sau `LEFT JOIN` là anti-join (mục 7) **chỉ khi** `o.id` không `NULL` trên hàng khớp (PK). Cột nullable khác không đủ để nhận “không khớp”. PG 19 có thể rewrite chuỗi `LEFT` + `IS NULL` thành ANTI — cùng kết quả nếu điều kiện anti đúng, plan khác.

---

## 5. CROSS

```sql
SELECT a.n AS day_offset, b.warehouse_id
FROM generate_series(0, 6) AS a(n)
CROSS JOIN warehouses AS b;
```

Không `ON`. Dùng calendar spine, numbers, mọi cặp ngày × kho. SQL Server: bảng số / `GENERATE_SERIES` (2022+).

Nhầm `CROSS` trên bảng lớn = incident. Review mọi `FROM a CROSS JOIN b` không `WHERE` hẹp / không `FETCH`.

**Ghi chú:** `CROSS JOIN LATERAL` (PG) / `CROSS APPLY` (SS) **không** phải tích vô điều kiện: phía phải phụ thuộc trái — mục 8.

`FULL OUTER JOIN` hai bảng không khóa chung sạch: `SELECT COALESCE(a.id, b.id)` — thiếu `COALESCE` thì PK “lạc” NULL một phía. `COUNT(*)` sau full outer ≠ `|A| + |B|` (trừ khi không khớp nào). Dùng khi đối soát hai nguồn (file vs bảng), không phải “LEFT cho chắc”.

---

## 6. Predicate: ON vs WHERE

### 6.0 Hình dung: OUTER là “giữ người bên trái, dù phải trống”

`INNER JOIN` = chỉ cặp **khớp**. `LEFT JOIN` = mọi hàng trái, phải **có thì điền, không thì NULL**.

`ON` quyết định **cặp nào được điền**. `WHERE` quyết định **hàng nào còn sau khi đã join**. Với `LEFT`, lọc cột *phải* trong `WHERE` biến NULL thành “loại hàng” → mất đúng những hàng outer sinh ra. Câu lệnh vẫn viết `LEFT` nhưng kết quả = `INNER`.

Đi từng hàng (Ada không đơn; Bob đơn paid; Cara đơn `new`):

```text
Sau FROM customers LEFT JOIN orders ON customer_id
  Ada  |  NULL,NULL     ← outer: không khớp khóa
  Bob  |  #9, paid
  Cara |  #8, new

Thêm AND o.status='paid' vào ON
  Ada  |  NULL,NULL     ← vẫn giữ: điều kiện paid thất bại ≠ xóa Ada
  Bob  |  #9, paid      ← khớp khóa + paid
  Cara |  NULL,NULL     ← có đơn nhưng không paid → coi như không khớp join

Đưa o.status='paid' xuống WHERE
  Ada  |  NULL = 'paid' → UNKNOWN → loại
  Bob  |  paid          → giữ
  Cara |  NULL = 'paid' → loại
  → chỉ còn Bob = INNER JOIN … AND status='paid'
```

Với **INNER JOIN**, `ON` và `WHERE` cùng predicate cho **cùng kết quả** (không có hàng “giữ với NULL”). Reviewer thấy `LEFT` + `WHERE` cột phải → đọc lại như trên, đừng tin tên `LEFT`.

Với **OUTER JOIN**, đẩy điều kiện phía *không được giữ hàng* xuống `WHERE` biến join thành **INNER**: hàng không khớp có cột phải = `NULL`, predicate `status = 'paid'` thành `UNKNOWN` → loại.

Ví dụ đủ — khách và đơn thanh toán, **vẫn giữ khách không có đơn paid**:

```sql
-- Đúng: lọc đơn trên ON — khách không khớp vẫn còn, o.* NULL
SELECT c.id, c.name, o.id AS order_id, o.total
FROM customers AS c
LEFT JOIN orders AS o
    ON o.customer_id = c.id
   AND o.status = 'paid';

-- Sai: lọc trên WHERE — khách không đơn / đơn không paid biến mất
SELECT c.id, c.name, o.id AS order_id, o.total
FROM customers AS c
LEFT JOIN orders AS o
    ON o.customer_id = c.id
WHERE o.status = 'paid';
```

Dữ liệu: khách Ada không đơn; Bob một đơn `paid`; Cara một đơn `new`.

| Câu | Ada | Bob | Cara |
|---|---|---|---|
| `ON … AND status = 'paid'` | 1 hàng, `order_id` NULL | 1 hàng paid | 1 hàng, `order_id` NULL |
| `WHERE o.status = 'paid'` | mất | 1 hàng paid | mất |

Điều kiện trên **bảng trái** (lọc khách) thường ở `WHERE` (`c.country = 'VN'`) — đó là lọc kết quả, không phải nhánh outer.

Chuỗi join: predicate `C` trên `LEFT JOIN C` phải ở `ON` của chính join đó, không gom một `WHERE` cuối.

**Ghi chú:** `INNER JOIN` + `WHERE` tương đương `ON` về kết quả. Reviewer thấy `LEFT` + `WHERE` cột phải → nghi ngay. Test bằng hàng cố ý không khớp, không chỉ happy path.

Collation / kiểu lệch trên khóa join: `customers.Name` `Vietnamese_CI_AS` ⋈ `orders.CustomerName` `Latin1_General_CI_AS` → implicit convert, mất index, có thể sai chữ. `varchar` ⋈ `nvarchar` trên SS: convert cột `varchar` (thường). Ép **phía tham số / bảng nhỏ**, hoặc thống nhất schema. PostgreSQL: `text` ⋈ `varchar` cùng collation thường ổn; `citext` / ICU khác = không join sargable.

Self-join: alias bắt buộc, khóa “cha-con” trên `ON`, không `NATURAL` (mọi cột cùng tên gồm `updated_at`).

```sql
SELECT c.id, c.name, p.name AS parent_name
FROM customers AS c
LEFT JOIN customers AS p ON p.id = c.parent_id;
```

---

## 7. Semi / anti & bẫy NOT IN NULL

**Hình dung.** Join thường **nhân hàng** (một khách 3 đơn → 3 hàng). Semi = câu hỏi có/không: “khách này *có* đơn không?” — trả khách **một lần**. Anti = “khách này *không* có đơn”.

`EXISTS` / `NOT EXISTS` đọc đúng câu hỏi đó. `IN` gần semi *nếu không NULL*. `NOT IN` với một `NULL` trong danh sách = hỏi “x khác mọi phần tử, kể cả *không biết*?” — logic ba giá trị trả **UNKNOWN**, `WHERE` loại hết. Không phải bug engine.

**Semi:** “trái có ít nhất một phải” — mỗi hàng trái **một lần**, dù nhiều con.

```sql
SELECT c.*
FROM customers AS c
WHERE EXISTS (
    SELECT 1 FROM orders AS o WHERE o.customer_id = c.id
);
```

`IN (SELECT customer_id FROM orders)` tương đương semi **nếu** cột subquery không `NULL` (hoặc `WHERE customer_id IS NOT NULL`). `INNER JOIN` + `DISTINCT`/`GROUP BY` làm việc tương tự nhưng dễ fan-out trước khi gộp — đắt và dễ sai `SUM`.

**Anti:** không có khớp. **Ưu tiên `NOT EXISTS`** (NULL-safe):

```sql
SELECT c.*
FROM customers AS c
WHERE NOT EXISTS (
    SELECT 1 FROM orders AS o WHERE o.customer_id = c.id
);

-- LEFT … IS NULL — tương đương anti nếu o.id NOT NULL
SELECT c.*
FROM customers AS c
LEFT JOIN orders AS o ON o.customer_id = c.id
WHERE o.id IS NULL;
```

### 7.1 `NOT IN` + NULL — bẫy đầy đủ

Ba giá trị: `TRUE` / `FALSE` / `UNKNOWN`. `WHERE` chỉ giữ `TRUE`.

`x NOT IN (a, b)` ≡ `x <> a AND x <> b`.  
`x <> NULL` ≡ `UNKNOWN` (không biết “khác” cái chưa có giá trị).  
`TRUE AND UNKNOWN` ≡ `UNKNOWN` → hàng biến mất. **Mọi** `x` đều biến mất nếu list có một NULL — kể cả `x = 1` và list là `(2, NULL)`.

```text
1 NOT IN (2, 3)     →  1≠2 AND 1≠3  → TRUE
1 NOT IN (2, NULL)  →  1≠2 AND 1≠NULL → TRUE AND UNKNOWN → UNKNOWN → loại
1 NOT IN (SELECT NULL)  → tương tự, kết quả rỗng
```

Đây là lý do **cấm** `NOT IN (SELECT nullable)` trên review. `NOT EXISTS` hỏi “có *hàng khớp* không?” — NULL trong đơn không biến cả truy vấn thành rỗng.

```sql
-- Subquery có NULL: cả biểu thức không bao giờ TRUE
SELECT c.id
FROM customers AS c
WHERE c.id NOT IN (SELECT o.customer_id FROM orders AS o);
-- Nếu một đơn có customer_id NULL → kết quả RỖNG (mọi hàng UNKNOWN)

SELECT 1 WHERE 1 NOT IN (2, 3);        -- 1
SELECT 1 WHERE 1 NOT IN (2, NULL);     -- 0 hàng
SELECT 1 WHERE 1 NOT IN (SELECT NULL); -- 0 hàng
```

`NOT IN` là `<> ALL`. `x <> NULL` = `UNKNOWN`. `UNKNOWN AND …` không qua `WHERE`.

Đừng “sửa” bằng `NOT IN` + hy vọng dữ liệu sạch. `NOT EXISTS` hoặc `NOT IN (SELECT … WHERE col IS NOT NULL)` nếu *thật sự* muốn bỏ NULL. SQL Server plan: `LEFT ANTI SEMI JOIN`. Không viết tay tên đó.

### 7.2 PG 19: ANTI JOIN rewrite

PostgreSQL **19** (**beta**):

- `NOT IN (SELECT …)` khi planner **chứng minh subquery không NULL** → rewrite **ANTI JOIN** (hash/nested loop anti), thường rẻ hơn `<> ALL` naively.
- Nhiều `LEFT JOIN` + predicate kiểu anti (`IS NULL` trên khóa phải) → **ANTI JOIN**.
- **Memoize** cho ANTI khi inner unique (nhớ kết quả lookup, giống Memoize nested loop).

Chứng minh không NULL: cột `NOT NULL`, hoặc subquery có `WHERE col IS NOT NULL`, hoặc constraint. **Nullable + NULL thật → bẫy logic mục 7.1 vẫn còn.** Optimizer không biến `NOT IN (nullable)` thành `NOT EXISTS`.

```sql
-- 19 có thể ANTI JOIN (customer_id NOT NULL)
SELECT c.id
FROM customers AS c
WHERE c.id NOT IN (
    SELECT o.customer_id FROM orders AS o WHERE o.customer_id IS NOT NULL
);

-- Vẫn RỖNG nếu bỏ IS NOT NULL và có một NULL
```

`EXPLAIN` 19: node `Anti Join` / `Hash Anti Join`. Trước 19: thường `Filter` + `SubPlan` / `hashed SubPlan`. Đo `EXPLAIN (ANALYZE, BUFFERS)` sau nâng — đừng đổi `NOT EXISTS` sang `NOT IN` chỉ vì “19 tối ưu”.

SQL Server: anti semi trên plan đã lâu; không cần đợi 2025. 2025 không thêm cú pháp anti.

**Ghi chú:** Fold `IS [NOT] DISTINCT FROM NULL` → `IS [NOT] NULL` (PG 19) giúp sargable/`NOT NULL` proof, không đổi three-valued `NOT IN`. Hash join 19 xử lý **NULL key** tốt hơn — equality join, không phải anti NULL trap.

---

## 8. APPLY vs LATERAL

Gọi bảng / hàm **phụ thuộc hàng trái**. SQL Server: `APPLY`. PostgreSQL / chuẩn: `LATERAL`.

```sql
-- SQL Server: 3 đơn lớn nhất mỗi khách
SELECT c.id, x.total, x.id AS order_id
FROM dbo.Customers AS c
CROSS APPLY (
    SELECT TOP (3) o.id, o.total
    FROM dbo.Orders AS o
    WHERE o.customer_id = c.id
    ORDER BY o.total DESC, o.id DESC
) AS x;

-- Không có đơn → khách biến mất. Giữ khách:
OUTER APPLY ( … ) AS x;
```

```sql
-- PostgreSQL
SELECT c.id, x.total, x.id AS order_id
FROM customers AS c
CROSS JOIN LATERAL (
    SELECT o.id, o.total
    FROM orders AS o
    WHERE o.customer_id = c.id
    ORDER BY o.total DESC, o.id DESC
    LIMIT 3
) AS x;

LEFT JOIN LATERAL (
    SELECT o.id, o.total
    FROM orders AS o
    WHERE o.customer_id = c.id
    ORDER BY o.total DESC, o.id DESC
    LIMIT 1
) AS x ON TRUE;
```

`LEFT JOIN LATERAL … ON TRUE` ≡ `OUTER APPLY`. `ON` khác `TRUE` vừa lateral vừa lọc — dễ viết sai; điều kiện tương quan để trong subquery.

**TVF / SRF**

```sql
-- SQL Server inline TVF
CREATE FUNCTION dbo.RecentOrders(@customer_id int)
RETURNS TABLE AS
RETURN (
    SELECT TOP (3) id, total
    FROM dbo.Orders
    WHERE customer_id = @customer_id
    ORDER BY total DESC
);

SELECT c.id, f.total
FROM dbo.Customers AS c
CROSS APPLY dbo.RecentOrders(c.id) AS f;
```

```sql
-- PostgreSQL SRF
SELECT g.n
FROM customers AS c
CROSS JOIN LATERAL generate_series(1, c.loyalty_tier) AS g(n);

SELECT u.tag
FROM customers AS c
CROSS JOIN LATERAL unnest(c.tags) AS u(tag);
```

Multi-statement TVF (SQL Server) tối ưu kém hơn inline. PostgreSQL function `RETURNS SETOF` trong `FROM` cần `LATERAL` nếu tham số là cột trái; `SELECT func(c.id)` trong list là SRF trong target (ngữ nghĩa hàng nhân — cẩn thận).

Index `(customer_id, total DESC, id DESC)` biến `APPLY`/`LATERAL` + `TOP`/`LIMIT` thành seek lặp — thường thắng `ROW_NUMBER` toàn bảng: [select.md](select.md) §10.

**Ghi chú:** `CROSS APPLY` với TVF trả 0 hàng **loại** hàng trái. Bug hay gặp khi “enrich” mà không `OUTER APPLY`. PostgreSQL quên `LATERAL`: lỗi “invalid reference to FROM-clause entry”.

---

## 9. Join algorithm

| Thuật toán | Khi nào | Rủi ro |
|---|---|---|
| Nested loop | Outer nhỏ-vừa, inner **seek** tốt (index = khóa) | Outer lớn + inner scan = thảm họa |
| Hash join | Equality, không cần thứ tự, bộ nhớ đủ | Spill `tempdb` / `work_mem`; build lớn |
| Merge join | Hai input đã sort / index theo khóa | Sort đắt nếu chưa thứ tự; `OR`/`<>` không merge |
| Adaptive (SQL Server) | Chọn loop/hash lúc chạy (batch, rồi row mode dần) | Vẫn phụ thuộc CE |
| Memoize (PostgreSQL) | Cache lookup nested loop / anti unique inner (**19** ANTI) | Ước lượng cache sai; `EXPLAIN` hiện hits |

```sql
-- Gợi ý — lock-in, chỉ sau khi đo
-- SQL Server
SELECT …
FROM dbo.Orders AS o
INNER JOIN dbo.Customers AS c ON c.Id = o.CustomerId
OPTION (LOOP JOIN);          -- hoặc HASH JOIN / MERGE JOIN

-- PostgreSQL (debug session, không production mặc định)
SET enable_hashjoin = off;
SET enable_mergejoin = off;
EXPLAIN (ANALYZE, BUFFERS)
SELECT …
```

Thống kê cũ → CE sai → hash khi nên loop (hoặc ngược). SQL Server 2025: CE feedback cho **expression**, OPPO (optional parameter), **DOP feedback mặc định** — mục 10.4, [select.md](select.md) §14. Không thay index thiếu.

Join không-equality (`ON a.ts BETWEEN b.start_at AND b.end_at`) → loop hoặc merge đặc biệt; interval: SQL Server không GiST; PostgreSQL GiST/`daterange` — [indexes.md](indexes.md).

```sql
-- Inequality: không hash. Index (start_at, end_at) / GiST daterange giúp loop
SELECT e.id, s.slot
FROM events AS e
JOIN slots AS s
  ON e.ts >= s.start_at AND e.ts < s.end_at;
```

`OR` hai equality (`ON a.id = b.id OR a.code = b.code`): `UNION` hai inner join thường ổn định hơn một nested loop kép.

```sql
SELECT a.id, b.val
FROM a
JOIN b ON a.id = b.id
UNION
SELECT a.id, b.val
FROM a
JOIN b ON a.code = b.code AND a.id <> b.id;  -- tránh trùng nếu cả hai khớp
```

(Điều kiện chống trùng tùy khóa — đừng copy mù.)

**Ghi chú:** `SET enable_* = off` trên PG là dao debug. Production: `pg_plan_advice` / `pg_stash_advice` (**19**, mục 10.3) nếu cần ghim — không copy GUC optimizer lên app pool. Hash 19 + NULL key: hai hàng `NULL = NULL` vẫn **không** khớp INNER (SQL); “xử lý NULL key tốt hơn” = ước lượng/build, không phải `NULL = NULL` thành TRUE.

---

## 10. Optimizer: PG 19 & SQL Server 2025

Ghi PG 19 **beta** — đối chiếu [release notes 19](https://www.postgresql.org/docs/19/release-19.html). SQL Server: compat **170** + Query Store.

### 10.1 PostgreSQL 19

- `NOT IN` (không NULL) → **ANTI JOIN** (mục 7.2).
- Nhiều `LEFT JOIN` + predicate anti → **ANTI JOIN**; Memoize ANTI khi inner unique.
- **Aggregate trước join** khi giảm cardinality (tự rewrite, giống mẹo thủ công mục 11).
- Hash join xử lý **NULL key** tốt hơn.
- Semi-join planning cải thiện.
- `Append` / `MergeAppend` cân incremental sort.
- FK check nhanh hơn (ảnh hưởng join **ẩn** khi DML, ít hơn `SELECT`).
- Fold `IS [NOT] DISTINCT FROM NULL` → `IS [NOT] NULL`; `COALESCE` / `ROW IS NULL`.
- Extended stats trên virtual generated — [ddl.md](ddl.md) §6.

`EXPLAIN (ANALYZE, IO)` async I/O; `EXPLAIN (ANALYZE, WAL)` FPI bytes; Memoize estimates. JIT **tắt mặc định** trên 19 — analytical join lớn có thể chậm hơn 18 nếu quên bật.

### 10.2 Memoize & aggregate trước join

**Memoize:** cache kết quả inner lookup theo khóa join trong nested loop. 19 mở ANTI unique inner. `EXPLAIN (ANALYZE)`: `Cache Hits` / `Misses`. Unique FK → hit cao. Khóa không unique / NDV cao → cache vô ích, tốn `work_mem`.

**Aggregate trước join:** planner 19 có thể gộp phía nhiều hàng *trước* khi join nếu kết quả logic tương đương (không đổi `SUM` sau Cartesian viết tay — SQL sai vẫn sai).

```sql
-- Viết: join rồi COUNT — 19 có thể agg items trước, rồi join orders
SELECT o.id, o.total, COUNT(i.id) AS items
FROM orders AS o
JOIN order_items AS i ON i.order_id = o.id
GROUP BY o.id, o.total;
```

Vẫn **không** an toàn khi join *hai* nhánh 1-n (mục 11): rewrite không gộp hai fan-out thành đúng `SUM(o.total)`.

Mẹo thủ công (portable, rõ nghĩa) vẫn nên viết khi hai collection — đừng chờ planner.

### 10.3 pg_plan_advice

Module contrib **`pg_plan_advice`** + **`pg_stash_advice`** (PostgreSQL **19**): ổn định / ghim plan theo query id. Không phải hint `/*+ HashJoin */` core; không bật mù trên mọi session pool.

Dùng khi: query ổn định, plan regress sau `ANALYZE` / nâng 19, đã hết thống kê + extended stats. Không thay index; không che `NOT IN` NULL.

SQL Server tương đương gần: Query Store force plan / `USE PLAN` — khác cơ chế, đo riêng.

`SET enable_hashjoin = off` vẫn dao debug, không phải advice.

Load contrib trên cụm lab trước prod: đối chiếu `CREATE EXTENSION` tên module trong docs 19 (`pg_plan_advice` / `pg_stash_advice`) — **không** nhét GUC `enable_*` vào connection string app. Advice theo query id: query đổi literal/`search_path` có thể khác id. Hết hạn advice sau `ANALYZE` lớn / đổi stats — review định kỳ, không “ghim mãi”.

### 10.4 SQL Server: CE, OPPO/PSPO, DOP

| Feature | 2025 | Ảnh hưởng join |
|---|---|---|
| DOP feedback **ON mặc định** | Parallel hash/loop đổi sau vài lần chạy | Spill `tempdb`, CXPACKET |
| CE feedback **expression** | Ước lượng `CAST`/công thức trên khóa join | Chọn hash vs loop |
| **OPPO** (optional parameter) | Multiplan (PSPO) cho `@p IS NULL OR col = @p` | Join + filter optional: nhiều plan cache |
| Query Store readable secondary **ON** | Plan join trên replica khác primary | I/O replica |
| Adaptive join | 2017+, mở rộng dần | Loop↔hash lúc chạy |

```sql
-- OPPO: optional customer filter + join
SELECT o.Id, c.Name
FROM dbo.Orders AS o
INNER JOIN dbo.Customers AS c ON c.Id = o.CustomerId
WHERE (@customerId IS NULL OR o.CustomerId = @customerId);
```

Một plan “seek CustomerId” sai khi `@customerId` NULL (phải scan). OPPO/PSPO cho phép nhiều plan — đo `sys.dm_exec_cached_plans` sau 170. Vẫn có thể viết hai procedure / dynamic SQL.

`ABORT_QUERY_EXECUTION`: chặn query độc, không chọn join type.

**Ghi chú:** Cải thiện rewrite PG không biến `NOT IN (nullable)` thành đúng. IQP không sửa fan-out. Đo `EXPLAIN (ANALYZE, BUFFERS)` / actual plan + Query Store; JIT PG 19 off.

---

## 11. Fan-out

Một fact join **hai** quan hệ 1-n cùng lúc: mỗi cặp con × con nhân đo lường.

```sql
-- Sai: SUM(o.total) bị nhân theo số item × số payment
SELECT o.id, SUM(o.total) AS total, COUNT(i.id) AS items, COUNT(p.id) AS pays
FROM orders AS o
JOIN order_items AS i ON i.order_id = o.id
JOIN payments AS p ON p.order_id = o.id
GROUP BY o.id;
```

Đơn `total = 100`, 2 item, 3 payment → 6 hàng join → `SUM(o.total)` = **600**, `COUNT(i.id)` = 6 (không phải 2).

**Sửa:** aggregate mỗi nhánh **trước**, rồi join 1-1:

```sql
SELECT o.id, o.total, i.items, p.pay_count
FROM orders AS o
LEFT JOIN (
    SELECT order_id, COUNT(*) AS items
    FROM order_items
    GROUP BY order_id
) AS i ON i.order_id = o.id
LEFT JOIN (
    SELECT order_id, COUNT(*) AS pay_count, SUM(amount) AS paid
    FROM payments
    GROUP BY order_id
) AS p ON p.order_id = o.id;
```

Hoặc `CROSS APPLY`/`LATERAL` scalar/`TOP 1` khi chỉ cần một con. Window `SUM() OVER (PARTITION BY o.id)` **không** cứu `SUM` sau Cartesian — window tính trên tập đã nhân.

`COUNT(DISTINCT i.id)` che `COUNT` items, **không** sửa `SUM(o.total)`:

```sql
-- Vẫn SAI total; items đúng nhờ DISTINCT
SELECT o.id,
       SUM(o.total) AS total,           -- vẫn × payments
       COUNT(DISTINCT i.id) AS items    -- đúng số item
FROM orders AS o
JOIN order_items AS i ON i.order_id = o.id
JOIN payments AS p ON p.order_id = o.id
GROUP BY o.id;
```

Ba nhánh (items, payments, refunds): ba subquery gộp, không một join phẳng.

ORM “include” hai collection rồi `Sum()` phía SQL = cùng bệnh. Graph `GRAPH_TABLE` nhiều hop 1-n cùng lúc = cùng fan-out sau rewrite.

Fan-out *ba* nhánh — đếm hàng join trước khi `SUM`:

```sql
-- Probe cardinality (cả hai engine)
SELECT
    COUNT(*) AS join_rows,
    COUNT(DISTINCT o.id) AS orders,
    COUNT(*) / NULLIF(COUNT(DISTINCT o.id), 0) AS avg_fanout
FROM orders AS o
JOIN order_items AS i ON i.order_id = o.id
JOIN payments AS p ON p.order_id = o.id;
-- avg_fanout > 1 ⇒ SUM(o.total) sau GROUP BY o.id sẽ nhân
```

Chỉ một nhánh 1-n (chỉ `items`, không `payments`): `SUM(o.total)` vẫn nhân theo số item — **cùng bệnh một nhánh**. `SUM(i.line_total)` thì đúng theo item; `SUM(o.total)` thì không. PG 19 rewrite agg-trước-join giúp khi gộp *phía item* trước, không biến `SUM(o.total)` thành đúng.

**Ghi chú:** Review `COUNT(*)` vs `COUNT(DISTINCT o.id)` — `DISTINCT` che fan-out, không sửa `SUM`. Test với 2 item × 3 payment cố ý. PG 19 agg-trước-join **một** nhánh, không cứu hai nhánh.

---

## 12. NATURAL JOIN & USING

```sql
-- Nguy hiểm
SELECT *
FROM orders NATURAL JOIN customers;
```

`NATURAL JOIN` = `INNER JOIN` trên **mọi cột cùng tên**. Thêm cột `updated_at` cả hai bảng → join thêm điều kiện, kết quả đổi **không lỗi parse**. Thêm `status` / `tenant_id` / `created_at` — cùng bẫy.

### 12.1 Schema evolution — worked trap

Trước:

```text
orders(id, customer_id, total)
customers(id, name)
NATURAL JOIN → ON orders.id = customers.id   -- SAI nghiệp vụ nếu nghĩ customer_id!
```

Đã nguy hiểm: `NATURAL` khớp `id` **cùng tên**, không khớp FK `customer_id`. Kết quả “đơn id=5 ⋈ khách id=5” — không phải chủ đơn.

Sau migration thêm `updated_at timestamptz` cả hai:

```text
NATURAL JOIN → ON orders.id = customers.id AND orders.updated_at = customers.updated_at
```

Hàng từng khớp `id` giờ **mất** vì timestamp khác. View `SELECT * FROM orders NATURAL JOIN customers` đổi silently. Test cũ không fail parse.

`USING (id)` rõ hơn `NATURAL` nhưng vẫn: chỉ các cột liệt kê, `SELECT *` gộp một cột `id`. Đổi tên cột = vỡ. `USING (customer_id)` **lỗi** nếu `customers` không có cột `customer_id`.

Viết `ON c.id = o.customer_id` — tên khác nhau, schema evolution không lặng.

SQL Server **không** có `USING`/`NATURAL` (T-SQL). Port `USING` sang T-SQL phải tách cột `ON`. Generated SQL / query builder đôi khi emit `NATURAL` — chặn ở review.

`SELECT *` + `USING` / `NATURAL`: cột gộp làm client bind lệch ordinal — [select.md](select.md) §7.

`NATURAL LEFT JOIN` / `NATURAL FULL JOIN`: cùng quy tắc *mọi cột cùng tên*, cộng ngữ nghĩa outer. Thêm cột cùng tên vừa đổi *khóa join* vừa đổi hàng NULL — hai bug một migration.

```sql
-- PG: NATURAL LEFT — vẫn khớp mọi tên trùng
SELECT *
FROM customers
NATURAL LEFT JOIN orders;   -- nếu cả hai có id, updated_at, status, …
```

Cột hệ thống / audit (`created_at`, `updated_at`, `created_by`, `tenant_id`) là nạn nhân điển hình khi “thêm chuẩn bảng”.

**Ghi chú:** Cấm `NATURAL` trong review. `USING` chỉ nội bộ PG, không API đa dialect. Không “rút gọn” `ON` thành `NATURAL` cho đẹp. Generated column cùng tên hai bảng = thêm điều kiện join.

---

## 13. Worked examples

### 13.1 Đơn giản — đơn kèm tên khách

```sql
SELECT o.id, o.total, c.name
FROM orders AS o
INNER JOIN customers AS c ON c.id = o.customer_id
WHERE o.status = 'paid';
```

`INNER`: đơn không khách (orphan) bị loại — đó là tín hiệu dữ liệu, không phải “mất LEFT”.

### 13.2 Trung bình — khách VN và đơn paid, giữ khách không đơn

```sql
SELECT c.id, c.name, o.id AS order_id, o.total
FROM customers AS c
LEFT JOIN orders AS o
    ON o.customer_id = c.id
   AND o.status = 'paid'
WHERE c.country = 'VN';
```

`country` trên `WHERE` (bảng giữ). `status` trên `ON`.

### 13.3 Nâng cao — top-N per group + anti + không fan-out

Khách không có đơn `cancelled`, kèm 2 SKU bán chạy (không nhân revenue):

```sql
-- PostgreSQL
SELECT c.id, c.name, x.sku, x.qty, r.revenue
FROM customers AS c
JOIN LATERAL (
    SELECT i.sku, SUM(i.qty) AS qty
    FROM orders AS o
    JOIN order_items AS i ON i.order_id = o.id
    WHERE o.customer_id = c.id
      AND o.status = 'paid'
    GROUP BY i.sku
    ORDER BY SUM(i.qty) DESC, i.sku
    LIMIT 2
) AS x ON TRUE
JOIN LATERAL (
    SELECT COALESCE(SUM(o.total), 0) AS revenue
    FROM orders AS o
    WHERE o.customer_id = c.id
      AND o.status = 'paid'
) AS r ON TRUE
WHERE NOT EXISTS (
    SELECT 1
    FROM orders AS o
    WHERE o.customer_id = c.id
      AND o.status = 'cancelled'
);
```

SQL Server: `CROSS APPLY` + `SELECT TOP (2) … ORDER BY`, `OUTER APPLY` nếu khách không SKU vẫn hiện; `NOT EXISTS` giữ nguyên. **Không** `NOT IN (SELECT status …)` nullable.

### 13.4 Fan-out hai nhánh — số liệu trước/sau

Đơn 1: `total = 100`, items A,B, payments 40+60.

| Cách viết | `SUM(o.total)` | `COUNT(items)` | `SUM(pay)` |
|---|---|---|---|
| Join phẳng 3 bảng rồi `GROUP BY o.id` | 400 (100×2×2) | 4 | 200×2 |
| Agg từng nhánh rồi `LEFT JOIN` | 100 (cột `o.total`) | 2 | 100 |

```sql
-- Đúng
SELECT o.id, o.total, i.n_items, p.paid
FROM orders AS o
LEFT JOIN (
    SELECT order_id, COUNT(*) AS n_items FROM order_items GROUP BY order_id
) AS i ON i.order_id = o.id
LEFT JOIN (
    SELECT order_id, SUM(amount) AS paid FROM payments GROUP BY order_id
) AS p ON p.order_id = o.id
WHERE o.id = 1;
```

### 13.5 NATURAL — thêm cột phá kết quả

```sql
-- PG: đừng
SELECT * FROM orders NATURAL JOIN customers;

-- Tường minh
SELECT o.id, o.total, c.name
FROM orders AS o
INNER JOIN customers AS c ON c.id = o.customer_id;
```

Sau `ALTER TABLE orders ADD updated_at`; `ALTER TABLE customers ADD updated_at` — câu `NATURAL` đổi, câu `ON` không.

### 13.6 LEFT + IS NULL vs NOT EXISTS (19 có thể cùng ANTI)

```sql
-- Cả hai: khách không đơn. o.id PK ⇒ IS NULL = anti
SELECT c.id
FROM customers AS c
LEFT JOIN orders AS o ON o.customer_id = c.id
WHERE o.id IS NULL;

SELECT c.id
FROM customers AS c
WHERE NOT EXISTS (
    SELECT 1 FROM orders AS o WHERE o.customer_id = c.id
);
```

`EXPLAIN` 19: cả hai có thể `Anti Join`. Cột `o.note IS NULL` **không** phải anti (đơn có note NULL vẫn khớp).

### 13.7 Optional parameter + join (SS OPPO)

```sql
-- SQL Server 2025: @country NULL = mọi nước
SELECT o.Id, c.Name, o.Total
FROM dbo.Orders AS o
INNER JOIN dbo.Customers AS c ON c.Id = o.CustomerId
WHERE (@country IS NULL OR c.Country = @country)
  AND o.CreatedAt >= @from;
```

Plan “seek Country” sai khi `@country` NULL. Compat 170 + OPPO/PSPO có thể nhiều plan; vẫn đo. Tách hai query (`IF @country IS NULL`) rõ hơn khi SLA hẹp. Chi tiết IQP: [select.md](select.md) §14.

### 13.8 Hash NULL key — INNER không khớp NULL

```sql
SELECT a.id, b.id
FROM staging_a AS a
INNER JOIN staging_b AS b ON a.ext_id = b.ext_id;
-- Hàng ext_id NULL hai phía: KHÔNG ra kết quả (NULL = NULL → UNKNOWN)
```

PG 19 hash “NULL key tốt hơn” không ghép hai NULL. Muốn “cả hai NULL là khớp”: `ON a.ext_id IS NOT DISTINCT FROM b.ext_id` (PG) / `ON (a.ext_id = b.ext_id OR (a.ext_id IS NULL AND b.ext_id IS NULL))` — khác equality thường, plan khác, **đừng** làm mặc định PK.

---

## 14. Best practices & checklist

- `ON` = quan hệ + lọc nhánh outer; `WHERE` = lọc kết quả / bảng “giữ hàng”.
- Semi/anti: `EXISTS` / `NOT EXISTS`, không `NOT IN` subquery nullable — kể cả PG 19 ANTI rewrite.
- Top-N per group: `APPLY`/`LATERAL` + index, hoặc `ROW_NUMBER` + CTE.
- Hai collection 1-n: aggregate trước, rồi join. Không tin `COUNT(DISTINCT)` cứu `SUM`.
- Khóa join cùng kiểu/collation; index FK.
- Cấm `NATURAL JOIN`; tránh `USING` trên API đa dialect.
- Hint join / `pg_plan_advice` / Query Store force chỉ sau `EXPLAIN` / actual plan và thống kê mới.
- Graph PG 19: index như join thường.
- Compat 170: baseline Query Store trước OPPO/DOP.

```text
□ LEFT + WHERE cột phải đã được giải thích (thật sự muốn INNER?)
□ NOT EXISTS thay NOT IN
□ Không SUM sau hai JOIN 1-n
□ APPLY/LATERAL: CROSS vs OUTER đúng ý
□ Index phía inner
□ Không NATURAL
□ Test hàng không khớp + 2×3 fan-out
□ EXPLAIN ANTI / Memoize sau nâng 19 — ngữ nghĩa NULL đã check
```

---

## 15. Bẫy khi review

- `LEFT JOIN` + `WHERE right.col = …` (mục 6).
- `NOT IN (SELECT nullable)`.
- Tin PG 19 anti-join rewrite sửa NULL.
- `JOIN` thiếu `ON` — PG/SS lỗi trên `INNER`; comma-style thì cross.
- Fan-out `orders` ⋈ `payments` ⋈ `items` rồi `SUM(orders.total)`.
- `COUNT(DISTINCT)` che fan-out, `SUM` vẫn sai.
- `COUNT(*)` sau left join nhân hàng, báo cáo “số khách” sai.
- `OR` trong `ON` hai khóa khác.
- Collation / `nvarchar` ⋈ `varchar`.
- `CROSS APPLY` khi cần `OUTER APPLY` (mất hàng trái).
- `NATURAL JOIN` trong view cũ; thêm cột cùng tên.
- Port `USING` sang SQL Server.
- `GRAPH_TABLE` không index FK.
- `SET enable_hashjoin = off` lên connection pool.
- Compat 170 không đo plan cache (OPPO tăng số plan).
- `UPDATE` join fan-out trên PostgreSQL — [dml.md](dml.md), không phải “JOIN SELECT”.

---

## 16. Version gates

| Mục | SQL Server | PostgreSQL |
|---|---|---|
| `FULL OUTER JOIN` | có | có |
| `NATURAL` / `USING` | không | có |
| `CROSS APPLY` / `OUTER APPLY` | có | không (dùng `LATERAL`) |
| `LATERAL` | không (dùng `APPLY`) | có |
| Adaptive join | 2017+ (mở rộng dần) | không |
| `NOT IN` → ANTI (không NULL) | anti semi trên plan lâu | **cải thiện 19** |
| LEFT → ANTI, Memoize ANTI | Memoize không cùng tên | **19** |
| Aggregate trước join (rewrite) | có tình huống | **cải thiện 19** |
| Hash NULL key | — | **19** |
| CE expression / OPPO / PSPO / DOP feedback | **2025** | generic/custom |
| `pg_plan_advice` / `pg_stash_advice` | Query Store force | **19** contrib |
| `GENERATE_SERIES` | 2022+ | lâu |
| SQL/PGQ join rewrite | không PGQ | **19 beta** |
| JIT default off | — | **19** |

Logical processing `FROM`/`ON`/`WHERE`: [select.md](select.md) §3. Isolation khi join rồi ghi: [transactions.md](transactions.md). IQP trên `SELECT`: [select.md](select.md) §14.
