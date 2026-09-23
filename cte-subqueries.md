# CTE & subquery

> **Baseline:** SQL Server **2025** · PostgreSQL **19**.  
> CTE là *tên* cho một truy vấn phụ trong *một* statement — không phải temp table, không phải transaction.

Subquery và CTE cùng mô hình: biểu thức bảng. Optimizer **được** inline, nhân bản, hoặc spool. PostgreSQL cho hint `MATERIALIZED` / `NOT MATERIALIZED`; SQL Server không — CTE bị tham chiếu nhiều lần có thể **chạy nhiều lần**. Đệ quy hai dialect lệch từ khóa (`RECURSIVE`), chặn vòng (`CYCLE` vs `MAXRECURSION`), và DML (`DELETE` qua CTE vs data-modifying `WITH`). File này là hợp đồng để review, không phải “WITH luôn chạy trước”.

Join semi/anti: [joins.md](joins.md). Logical `SELECT`: [select.md](select.md). Window trong CTE: [window-functions.md](window-functions.md). Graph metadata (SQL/PGQ): [select.md](select.md), [ddl.md](ddl.md) — **không** thay path biến độ dài; dùng recursive CTE dưới đây.

---

## Mục lục

- [1. Tổng quan \& triết lý](#1-tổng-quan--triết-lý)
- [2. Scalar subquery](#2-scalar-subquery)
- [3. `IN` / `EXISTS`](#3-in--exists)
- [4. Derived table](#4-derived-table)
- [5. CTE không đệ quy](#5-cte-không-đệ-quy)
  - [5.1 Bẫy `;WITH`](#51-bẫy-with)
- [6. `RECURSIVE`](#6-recursive)
- [7. Graph path: recursive, không PGQ biến độ dài](#7-graph-path-recursive-không-pgq-biến-độ-dài)
- [8. `CYCLE` \& `SEARCH` (PostgreSQL)](#8-cycle--search-postgresql)
- [9. `MAXRECURSION` (SQL Server)](#9-maxrecursion-sql-server)
- [10. Materialize / inline](#10-materialize--inline)
- [11. `UPDATE` / `DELETE` + CTE](#11-update--delete--cte)
- [12. `LATERAL` / `APPLY`](#12-lateral--apply)
- [13. Worked examples](#13-worked-examples)
- [14. Nhiều anchor \& đi lên cây](#14-nhiều-anchor--đi-lên-cây)
- [15. `INSERT`/`MERGE` + CTE](#15-insertmerge--cte)
- [16. Best practices \& checklist](#16-best-practices--checklist)
- [17. Bẫy khi review](#17-bẫy-khi-review)
- [18. Version gates](#18-version-gates)
- [Phụ lục A. CTE vs view vs temp](#phụ-lục-a-cte-vs-view-vs-temp)

---

## 1. Tổng quan & triết lý

Ba hình:

| Hình | Phạm vi tên | Tương quan | Ghi chú |
|---|---|---|---|
| Scalar / `IN` / `EXISTS` | trong biểu thức | được | 0/1 hàng (scalar) hoặc membership |
| Derived table (`FROM (SELECT…)`) | alias bắt buộc (SS) | không, trừ `LATERAL`/`APPLY` | một lần dùng |
| CTE (`WITH`) | statement | CTE sau thấy CTE trước | nhiều lần dùng; đệ quy |

CTE **không** tạo object catalog, **không** thống kê riêng (trừ khi bị materialize thành spool/temp). Hint `WITH (NOLOCK)` trên tên CTE là hint *view-like* tới base — dễ xung đột.

Chọn CTE khi: tái sử dụng, đọc được chuỗi bước, đệ quy, DML bọc. Chọn subquery khi: một lần, scalar, semi-join. Chọn `#temp` / `temp table` khi: cần index / thống kê / tái sử dụng *nhiều statement*.

---

## 2. Scalar subquery

Một cột, **tối đa một hàng**:

```sql
SELECT
    o.id,
    (SELECT MAX(p.paid_at) FROM payments p WHERE p.order_id = o.id) AS last_paid
FROM orders o;
```

| Kết quả subquery | Giá trị |
|---|---|
| 0 hàng | `NULL` |
| 1 hàng | giá trị cột |
| >1 hàng | **lỗi runtime** (`Subquery returned more than 1 value` / `more than one row returned`) |

Không có `ORDER BY` + `TOP`/`LIMIT` thì “hàng nào” khi >1 là lỗi, không phải “hàng bất kỳ im lặng” — trừ khi engine biến thành `MIN`/`MAX` vì bạn đã viết vậy.

Tương quan: subquery tham chiếu cột ngoài. Không index `(order_id)` → N+1. Viết lại `LEFT JOIN LATERAL` / `OUTER APPLY` + `MAX` / `TOP 1`, hoặc `LEFT JOIN` aggregate.

**Ghi chú:** `(SELECT col FROM t WHERE …)` thiếu `MAX`/`TOP 1` khi unique không được *khai báo* — unique hôm nay, duplicate ngày mai = incident production.

---

## 3. `IN` / `EXISTS`

```sql
-- Semi: có ít nhất một payment
WHERE o.id IN (SELECT order_id FROM payments)
WHERE EXISTS (SELECT 1 FROM payments p WHERE p.order_id = o.id)

-- Anti
WHERE NOT EXISTS (SELECT 1 FROM payments p WHERE p.order_id = o.id)
```

`IN (SELECT nullable)` + `NOT IN`: một `NULL` trong list → `NOT IN` thành `UNKNOWN` cho mọi hàng — [operators.md](operators.md), [joins.md](joins.md). **Luôn** `NOT EXISTS` cho anti-join.

`EXISTS` chỉ cần *có hàng*; `SELECT 1` / `SELECT *` / `SELECT PK` cùng nghĩa. Optimizer cả hai engine hiểu semi/anti join.

List hằng `IN (1,2,3)` ≠ subquery: cardinality cố định. `IN` tuple:

```sql
-- PostgreSQL
WHERE (customer_id, sku) IN (SELECT customer_id, sku FROM promo)

-- SQL Server: không có IN tuple kiểu này; JOIN / EXISTS hai cột
WHERE EXISTS (
    SELECT 1 FROM dbo.Promo p
    WHERE p.customer_id = o.customer_id AND p.sku = o.sku
)
```

PG 19: `NOT IN` *chứng minh không NULL* có thể rewrite ANTI JOIN — ngữ nghĩa NULL **vẫn** bẫy nếu cột nullable có NULL thật.

**Ghi chú:** `WHERE id = (SELECT …)` là scalar, không phải `IN`. 0 hàng → `id = NULL` → loại hàng; >1 → lỗi.

---

## 4. Derived table

```sql
SELECT s.customer_id, s.revenue
FROM (
    SELECT customer_id, SUM(total) AS revenue
    FROM orders
    GROUP BY customer_id
) AS s
WHERE s.revenue > 1000;
```

Alias bảng **bắt buộc** trên SQL Server (`Incorrect syntax near ')'` nếu thiếu). PostgreSQL cũng nên đặt alias (bắt buộc ở hầu hết phiên bản cho subquery `FROM`).

Derived table không tương quan — không tham chiếu `FROM` bên trái trừ khi `LATERAL` / `APPLY` (§12).

`ORDER BY` trong derived **bị bỏ** trừ khi có `TOP`/`OFFSET`/`FETCH` (SS) hoặc `LIMIT`/`FETCH` (PG). Đừng “sắp trong CTE rồi tin ngoài”.

---

## 5. CTE không đệ quy

```sql
WITH paid AS (
    SELECT * FROM orders WHERE status = 'paid'
),
agg AS (
    SELECT customer_id, SUM(total) AS revenue
    FROM paid
    GROUP BY customer_id
)
SELECT * FROM agg WHERE revenue > 1000;
```

Nhiều CTE: cách nhau `,`. CTE sau thấy CTE trước; **không** forward-reference. Một `WITH` — không lồng `WITH` trong định nghĩa CTE (SS cấm nested `WITH` trong CTE_query_definition).

`WITH` đứng **đầu** statement (`SELECT`/`INSERT`/`UPDATE`/`DELETE`/`MERGE`; PG thêm được CTE *là* DML — §11).

Cột: `WITH t (a, b) AS (SELECT …)` đặt tên; số cột phải khớp. `SELECT *` trong CTE **đóng băng** danh sách lúc parse — thêm cột bảng gốc **không** tự xuất hiện ở caller đã liệt kê tên.

### 5.1 Bẫy `;WITH`

SQL Server: `WITH` cũng là hint table (`WITH (NOLOCK)`). Statement *trước* trong batch **phải** kết thúc `;`, nếu không parser nuốt `WITH` như hint.

```sql
UPDATE dbo.T SET x = 1          -- thiếu ;
WITH x AS (SELECT 1 AS n)       -- lỗi / hiểu sai
SELECT * FROM x;
```

Quy ước phổ biến: luôn `;WITH` khi viết CTE giữa batch:

```sql
;WITH x AS (SELECT 1 AS n)
SELECT * FROM x;
```

PostgreSQL không có hint `WITH (NOLOCK)` — `;` trước `WITH` không bắt buộc theo cùng lý do, vẫn nên tách statement.

**Ghi chú:** Tool gen SQL ghép proc không `;` rồi dán CTE = lỗi 319 / “Incorrect syntax near the keyword 'with'”. Checklist review batch T-SQL.

---

## 6. `RECURSIVE`

**Hình dung: đi từng thế hệ, không nhìn cả cây một lúc.**

Anchor = “bắt đầu từ sếp id=1”. Vòng sau chỉ thấy **con của những người vừa tìm ở vòng trước**, không thấy ông nội trừ khi bạn tự ghi cột `path`. Không có điều kiện dừng (`depth`, `CYCLE`, `MAXRECURSION`) thì vòng tròn org → chạy mãi.

```text
Vòng 0 (anchor):     [CEO]
Vòng 1:              [VP-A, VP-B]          JOIN org ON parent = người vòng 0
Vòng 2:              [staff của VP]        JOIN trên kết quả vòng 1, không phải cả bảng lịch sử
Kết quả = UNION ALL mọi vòng
```

Hai thành phần: **anchor** (không tự tham chiếu) + **recursive member** (`UNION ALL` tới CTE). Mỗi bước chỉ thấy *working table* vòng trước, không thấy toàn bộ lịch sử trừ khi bạn tự mang cột path.

```sql
-- PostgreSQL: WITH RECURSIVE bắt buộc
WITH RECURSIVE walk AS (
    SELECT id, parent_id, 1 AS depth
    FROM org
    WHERE id = 1
    UNION ALL
    SELECT c.id, c.parent_id, w.depth + 1
    FROM org c
    JOIN walk w ON c.parent_id = w.id
    WHERE w.depth < 20
)
SELECT * FROM walk;

-- SQL Server: không từ khóa RECURSIVE; UNION ALL
WITH walk AS (
    SELECT Id, ParentId, 1 AS Depth
    FROM dbo.Org
    WHERE Id = 1
    UNION ALL
    SELECT c.Id, c.ParentId, w.Depth + 1
    FROM dbo.Org AS c
    INNER JOIN walk AS w ON c.ParentId = w.Id
    WHERE w.Depth < 20
)
SELECT * FROM walk
OPTION (MAXRECURSION 100);
```

| Quy tắc | PostgreSQL | SQL Server |
|---|---|---|
| Từ khóa | `WITH RECURSIVE` (thiếu = CTE thường, lỗi tự tham chiếu) | không có `RECURSIVE` |
| Recursive ↔ anchor | `UNION` hoặc `UNION ALL` | `UNION ALL` **bắt buộc** giữa anchor cuối và recursive |
| Tham chiếu CTE trong recursive | **một** lần trong `FROM` | **một** lần |
| `LEFT`/`RIGHT`/`FULL JOIN` CTE | hạn chế (cẩn thận vòng) | **cấm** trên recursive member (`INNER JOIN` được) |
| `GROUP BY` / `DISTINCT` / `TOP` / subquery trong recursive member | hạn chế tùy dạng | **cấm** (list Learn: không `GROUP BY`, `HAVING`, `DISTINCT`, `TOP`, subquery, `PIVOT`, scalar aggregate) |
| Cột | cùng số/kiểu | cùng số; kiểu recursive = kiểu anchor; **mọi cột kết quả nullable** |

`UNION` (distinct) có thể chặn vòng khi cả hàng trùng; **không** đủ nếu cột `depth` đổi. Luôn điều kiện dừng (`depth < n`) hoặc `CYCLE` / `MAXRECURSION`.

**Ghi chú:** Recursive member SS không `LEFT JOIN` “cha không con”. Lọc `parent_id IS NULL` ở anchor, đi xuống bằng `INNER JOIN`.

---

## 7. Graph path: recursive, không PGQ biến độ dài

PostgreSQL **19** SQL/PGQ: `CREATE PROPERTY GRAPH` + `GRAPH_TABLE` / `MATCH` là **metadata** trên bảng vertex/edge đã có. Planner rewrite thành join thường — không engine graph riêng. Index PK/FK vẫn bắt buộc. DDL / `FROM GRAPH_TABLE`: [ddl.md](ddl.md), [select.md](select.md). Kiến trúc: [internal.md](internal.md).

**19 chưa có:** variable-length `{1,4}`, shortest path, path variable đầy đủ. Path trong `MATCH` là **cố định** (một bước, hoặc số bước viết tay). Đường đi độ dài không biết = **recursive CTE** (mục 6–9), không phải chờ PGQ.

SQL Server `AS NODE` / `AS EDGE` / `MATCH` là **SQL Graph** cũ — **không** phải SQL/PGQ. Đừng port `GRAPH_TABLE` sang T-SQL hay ngược lại. SQL Graph SS có `MATCH` pattern ngắn; path biến độ dài vẫn thường recursive CTE / `SHORTEST_PATH` (surface Graph SS — đối chiếu Learn, không trộn PGQ).

```sql
-- Cả hai ý: mọi hậu duệ từ gốc, trần depth — công cụ chính trên PG 19
-- (PG: WITH RECURSIVE; SS: WITH + MAXRECURSION)
```

**Ghi chú:** Review `GRAPH_TABLE` kỳ vọng “mọi đường ≤ 4 cạnh” trên 19 beta → viết recursive + `depth <= 4` + `CYCLE`. `EXPLAIN` PGQ = join; thiếu FK index = nested loop nặng.

---

## 8. `CYCLE` & `SEARCH` (PostgreSQL)

PG **14+** (vẫn đúng trên 19). SQL Server **không** có `CYCLE`/`SEARCH`. Chỉ hợp lệ trên CTE **recursive**, dạng `UNION`/`UNION ALL` hai nhánh (không `UNION` lồng).

```sql
WITH RECURSIVE walk AS (
    SELECT id, parent_id, 1 AS depth
    FROM graph
    WHERE id = 1
    UNION ALL
    SELECT g.id, g.parent_id, w.depth + 1
    FROM graph g
    JOIN walk w ON g.parent_id = w.id
)
CYCLE id SET is_cycle USING path_arr
SELECT * FROM walk WHERE NOT is_cycle;
```

`CYCLE col … SET mark USING path`: thêm cột `mark` (`TRUE` khi bước này đóng vòng) và `path` (array đã đi). Recursive **dừng mở rộng** khi phát hiện cycle. Mặc định mark `TRUE`/`FALSE`; có thể `SET is_cycle TO 'Y' DEFAULT 'N'` — hai giá trị phải so sánh được (`<>`).

Nhiều cột khóa: `CYCLE id, version SET …`. Cột `mark` và `path` **thêm** vào output CTE (sau cột `SEARCH` nếu có cả hai).

Thủ công tương đương (trước 14, hoặc SS, hoặc cần tùy biến):

```sql
SELECT g.id, w.depth + 1, w.path || g.id
FROM graph g
JOIN walk w ON g.parent_id = w.id
WHERE NOT g.id = ANY (w.path)
```

SQL Server: mang `path` `nvarchar` / hierarchyid / JSON, kiểm `LIKE` / `OPENJSON` — không array `= ANY`.

### `SEARCH`

`SEARCH` **không** đổi thứ tự engine duyệt (implementation-dependent). Nó **thêm cột** để `ORDER BY` ngoài theo DFS/BFS.

```sql
WITH RECURSIVE search_tree AS (
    SELECT t.id, t.link, t.data
    FROM tree t
    WHERE t.id = 1
    UNION ALL
    SELECT t.id, t.link, t.data
    FROM tree t
    JOIN search_tree st ON t.id = st.link
)
SEARCH DEPTH FIRST BY id SET ordercol
SELECT * FROM search_tree ORDER BY ordercol;

-- BFS
-- ) SEARCH BREADTH FIRST BY id SET ordercol
```

Docs 19: DFS + `CYCLE` tính path trùng — hiệu quả hơn **chỉ `CYCLE` rồi `ORDER BY path`**. BFS + `CYCLE` kết hợp hữu ích khi cần cả thứ tự mức lẫn chặn vòng.

Không có `MAXRECURSION`. An toàn: `depth < n`, `CYCLE`, `statement_timeout`. `max_stack_depth` **không** phải giới hạn vòng CTE (CTE lặp working table, không gọi stack SQL từng mức như hàm đệ quy).

**Ghi chú:** Đừng viết `max_recursion_depth` như GUC — **không** tồn tại trên PG 19. Chặn vòng = `CYCLE` hoặc `path`/`depth`.

---

## 9. `MAXRECURSION` (SQL Server)

Mặc định **100** mức. `OPTION (MAXRECURSION n)` với `n` ∈ 0…32767; **0** = không giới hạn. Vượt → lỗi **530**, statement abort.

```sql
SELECT * FROM walk
OPTION (MAXRECURSION 0);
```

`OPTION` chỉ ở **câu ngoài cùng**, không nhét trong định nghĩa CTE, view, **inline TVF**. Gọi TVF chứa recursive CTE:

```sql
SELECT * FROM dbo.WalkFrom(@root)
OPTION (MAXRECURSION 0);
```

Hint nằm ở *câu gọi*, không trong `RETURN (SELECT …)` của inline TVF. MSTVF *có thể* `OPTION` trên `INSERT…SELECT` nội bộ — đánh đổi cardinality: [routines.md](routines.md).

`MAXRECURSION` **không** thay `CYCLE`. Cây hợp lệ sâu 101 vẫn chết ở mặc định 100. Graph có vòng + `MAXRECURSION 0` = chạy đến khi cancel / log đầy.

Đếm mức = số lần recursive member chạy, không phải “số hàng”. Cây rộng nông: 5 mức, 1e6 hàng — không dính 530; cây sâu 101 một nhánh — dính.

**Ghi chú:** Review `MAXRECURSION 0` trên input user (org tree) mà không `depth` / detect cycle = DoS. Production: trần `depth` *và* `MAXRECURSION` khớp trần.

---

## 10. Materialize / inline

**Hình dung.** CTE là **công thức**, không phải tô đã nấu. Gọi hai lần có thể nấu hai lần (inline) hoặc nấu một lần rồi múc (materialize). SQL Server thường nấu lại. PostgreSQL 12+ hay nấu một lần khi CTE được gọi **hai lần** — trừ khi bạn viết `NOT MATERIALIZED`.

Hệ quả: `random()` / `NEWID()` trong CTE rồi `JOIN` hai alias → hai số khác nhau nếu nấu lại; một số nếu múc. Predicate `WHERE id = 1` **không** đẩy vào công thức đã nấu sẵn (materialize) — scan cả tô. Inline thì index vẫn dùng được.

CTE **không** phải temp. SS docs: mỗi tham chiếu có thể **re-execute**. PG 12+: CTE không đệ quy, không volatile, *một* tham chiếu → thường **inline**; *nhiều* tham chiếu → thường **materialize**.

```sql
-- PostgreSQL: buộc spool (tính một lần, mất pushdown predicate)
WITH t AS MATERIALIZED (
    SELECT * FROM big_table
)
SELECT * FROM t JOIN t AS t2 ON t.id = t2.parent_id;

-- Buộc inline (có thể tính hai lần; cho phép index/pushdown mỗi nhánh)
WITH t AS NOT MATERIALIZED (
    SELECT * FROM big_table
)
SELECT * FROM t WHERE id = 1
UNION ALL
SELECT * FROM t WHERE id = 2;
```

`NOT MATERIALIZED` **bị bỏ qua** nếu CTE recursive hoặc có side-effect (volatile / DML).

SQL Server: không hint `MATERIALIZED` trên CTE. Cần một lần tính + index: `#temp` / table variable (thống kê kém) / temp table + `CREATE INDEX`. View indexed / persisted không áp cho CTE.

CTE gọi `NEWID()` / `random()` / `NEXT VALUE FOR` rồi join hai lần: SS có thể bắn hai lần; PG materialize mặc định khi hai tham chiếu (không volatile thì một tham chiếu thường inline). Test, đừng đoán.

**Ghi chú:** `EXPLAIN (ANALYZE)` PG ghi `CTE Scan` khi materialize. SS: xem actual vs estimated trên nhánh CTE — hai seek giống nhau = re-execute.

---

## 11. `UPDATE` / `DELETE` + CTE

**SQL Server:** `WITH` gắn lên DML; `UPDATE`/`DELETE` *tên CTE* = sửa **bảng gốc** nếu CTE updatable (một base table, không aggregate).

```sql
;WITH stale AS (
    SELECT TOP (1000) *
    FROM dbo.Orders
    WHERE status = N'stale'
    ORDER BY id
)
DELETE FROM stale;

;WITH src AS (
    SELECT Id, Total FROM dbo.Staging
)
UPDATE o
SET Total = s.Total
FROM dbo.Orders AS o
INNER JOIN src AS s ON s.Id = o.Id;

;WITH bump AS (
    SELECT TOP (100) Id, Score
    FROM dbo.Items
    WHERE Score < 10
    ORDER BY Id
)
UPDATE bump
SET Score = Score + 1;

;WITH dead AS (
    SELECT p.*
    FROM dbo.Parts AS p
    WHERE NOT EXISTS (
        SELECT 1 FROM dbo.Bom AS b WHERE b.PartId = p.Id
    )
)
DELETE FROM dead;
```

`DELETE FROM cte` không xóa “biến CTE” — xóa hàng base. View/CTE không updatable (join/aggregate) → lỗi. `OUTPUT deleted.* INTO …` trên `DELETE`/`UPDATE` CTE được, giống DML thường — [dml.md](dml.md).

**PostgreSQL:** hai kiểu.

```sql
-- 1) CTE SELECT, DML chính tham chiếu
WITH stale AS (
    SELECT id FROM orders WHERE status = 'stale'
    ORDER BY id
    LIMIT 1000
)
DELETE FROM orders o
USING stale s
WHERE o.id = s.id;

WITH src AS (
    SELECT id, total FROM staging
)
UPDATE orders o
SET total = s.total
FROM src s
WHERE o.id = s.id;

-- 2) Data-modifying CTE (INSERT/UPDATE/DELETE/MERGE trong WITH) + RETURNING
WITH moved AS (
    DELETE FROM staging
    RETURNING *
)
INSERT INTO archive SELECT * FROM moved;

WITH ins AS (
    INSERT INTO orders (customer_id, total)
    SELECT customer_id, total FROM staging
    RETURNING id, customer_id
),
upd AS (
    UPDATE customers c
    SET last_order_id = ins.id
    FROM ins
    WHERE c.id = ins.customer_id
    RETURNING c.id
)
SELECT COUNT(*) FROM upd;

WITH d AS (
    DELETE FROM parts p
    WHERE NOT EXISTS (SELECT 1 FROM bom b WHERE b.part_id = p.id)
    RETURNING id
)
DELETE FROM part_notes n
USING d
WHERE n.part_id = d.id;
```

Data-modifying CTE chỉ ở `WITH` **top-level**. Các nhánh DML trong cùng statement chạy **cùng snapshot**, thứ tự ghi **không** đảm bảo; giao tiếp duy nhất = `RETURNING`. A xóa hàng X, B không thấy hiệu ứng A trên bảng — chỉ thấy hàng `RETURNING`.

SQL Server không có DML-trong-`WITH` kiểu PG. Chuỗi xóa-rồi-insert: `DELETE … OUTPUT deleted.* INTO archive` hoặc hai statement một txn.

`MERGE` + CTE: race isolation — [dml.md](dml.md), [transactions.md](transactions.md). Đừng giả định CTE “chụp snapshot” rồi `MERGE` an toàn dưới RC.

**Ghi chú:** Batch xóa 1000 hàng: CTE + `TOP`/`LIMIT` trong vòng lặp / job, không một `DELETE` 50 triệu. PG `DELETE … USING cte`; SS `DELETE cte`. Đừng `DELETE FROM t WHERE id IN (SELECT id FROM cte)` nếu CTE đã là tập cần xóa *và* cần `OUTPUT`/`RETURNING` — viết DML trực tiếp.

---

## 12. `LATERAL` / `APPLY`

Subquery / TVF / SRF trong `FROM` **tham chiếu alias trái**: PostgreSQL `LATERAL`; SQL Server `CROSS APPLY` / `OUTER APPLY`. Chi tiết join: [joins.md](joins.md).

```sql
-- PostgreSQL: 1 post mới nhất / user
SELECT u.id, p.caption
FROM users u
LEFT JOIN LATERAL (
    SELECT caption
    FROM posts
    WHERE user_id = u.id
    ORDER BY created_at DESC, id DESC
    LIMIT 1
) p ON TRUE;

-- SQL Server
SELECT u.Id, p.Caption
FROM dbo.Users AS u
OUTER APPLY (
    SELECT TOP (1) Caption
    FROM dbo.Posts
    WHERE UserId = u.Id
    ORDER BY CreatedAt DESC, Id DESC
) AS p;
```

`CROSS JOIN LATERAL` / `CROSS APPLY`: 0 hàng phải → **loại** hàng trái. Enrich nullable: `LEFT JOIN LATERAL … ON TRUE` / `OUTER APPLY`.

PostgreSQL quên `LATERAL` khi cột trái dùng trong subquery `FROM` → `invalid reference to FROM-clause entry`. Hàm `FROM fn(u.id)` cần `LATERAL` nếu `u` đứng trước.

Scalar correlated ≡ `LEFT JOIN LATERAL` một cột. Top-N per group: `LATERAL` + index thường rõ plan hơn window trên cả bảng.

**Ghi chú:** `ON` khác `TRUE` vừa lateral vừa lọc — hàng trái mất như inner. Điều kiện tương quan để *trong* subquery; `ON TRUE` cho `LEFT`.

---

## 13. Worked examples

**Cây org + chặn vòng hai dialect**

```sql
-- PostgreSQL 14+
WITH RECURSIVE walk AS (
    SELECT id, parent_id, name, 1 AS depth
    FROM org
    WHERE id = @root
    UNION ALL
    SELECT c.id, c.parent_id, c.name, w.depth + 1
    FROM org c
    JOIN walk w ON c.parent_id = w.id
    WHERE w.depth < 50
)
CYCLE id SET is_cycle USING path
SELECT * FROM walk WHERE NOT is_cycle
ORDER BY path;

-- SQL Server
;WITH walk AS (
    SELECT Id, ParentId, Name, 1 AS Depth,
           CAST(CAST(Id AS varchar(20)) AS varchar(max)) AS Path
    FROM dbo.Org
    WHERE Id = @root
    UNION ALL
    SELECT c.Id, c.ParentId, c.Name, w.Depth + 1,
           CAST(w.Path + N'/' + CAST(c.Id AS varchar(20)) AS varchar(max))
    FROM dbo.Org AS c
    INNER JOIN walk AS w ON c.ParentId = w.Id
    WHERE w.Depth < 50
      AND CHARINDEX(N'/' + CAST(c.Id AS varchar(20)) + N'/', N'/' + w.Path + N'/') = 0
)
SELECT * FROM walk
OPTION (MAXRECURSION 50);
```

**Chuyển staging → archive một statement (PG) vs OUTPUT (SS)**

```sql
-- PostgreSQL
WITH moved AS (
    DELETE FROM staging
    WHERE loaded_at < now() - interval '7 days'
    RETURNING *
)
INSERT INTO archive SELECT * FROM moved;

-- SQL Server
DELETE FROM dbo.Staging
OUTPUT deleted.* INTO dbo.Archive
WHERE LoadedAt < DATEADD(day, -7, SYSUTCDATETIME());
```

**CTE đắt dùng hai lần**

```sql
-- PostgreSQL
WITH heavy AS MATERIALIZED (
    SELECT customer_id, sum(total) AS rev
    FROM orders
    GROUP BY customer_id
)
SELECT a.customer_id, a.rev, b.rev AS parent_rev
FROM heavy a
LEFT JOIN customers c ON c.id = a.customer_id
LEFT JOIN heavy b ON b.customer_id = c.parent_id;

-- SQL Server: #temp
SELECT customer_id, SUM(total) AS rev
INTO #heavy
FROM dbo.Orders
GROUP BY customer_id;
CREATE CLUSTERED INDEX ix ON #heavy (customer_id);
```

---

## 14. Nhiều anchor & đi lên cây

Nhiều `UNION ALL` *trước* recursive member = nhiều gốc. Recursive member vẫn **một** tham chiếu CTE.

```sql
-- PostgreSQL: hai gốc, cùng cây xuống
WITH RECURSIVE walk AS (
    SELECT id, parent_id, 1 AS depth FROM org WHERE id IN (1, 99)
    UNION ALL
    SELECT c.id, c.parent_id, w.depth + 1
    FROM org c
    JOIN walk w ON c.parent_id = w.id
    WHERE w.depth < 20
)
CYCLE id SET is_cycle USING path
SELECT * FROM walk WHERE NOT is_cycle;
```

SQL Server: cùng hình, `UNION ALL` giữa các anchor rồi `UNION ALL` recursive; `OPTION (MAXRECURSION)` ngoài. Trùng hàng nếu hai gốc chung hậu duệ — `DISTINCT` **cấm** trên recursive member SS: lọc ngoài hoặc mang cờ nguồn.

Đi **lên** (tổ tiên): đảo join — `JOIN walk w ON c.id = w.parent_id` (con → cha). Trần `depth` vẫn bắt buộc. PGQ `MATCH` một cạnh không thay chuỗi tổ tiên độ dài không biết.

```sql
-- Tổ tiên của @id (SS)
;WITH up AS (
    SELECT Id, ParentId, 1 AS Depth
    FROM dbo.Org WHERE Id = @id
    UNION ALL
    SELECT p.Id, p.ParentId, u.Depth + 1
    FROM dbo.Org AS p
    INNER JOIN up AS u ON p.Id = u.ParentId
    WHERE u.Depth < 50
)
SELECT * FROM up
OPTION (MAXRECURSION 50);
```

View chứa recursive CTE: caller SS **không** nhét `MAXRECURSION` vào định nghĩa view — đặt `OPTION` trên `SELECT` từ view. Inline TVF cùng quy tắc — [routines.md](routines.md).

---

## 15. `INSERT`/`MERGE` + CTE

`WITH` đứng trước `INSERT`/`MERGE` như `DELETE`/`UPDATE`. CTE là nguồn hoặc (SS) đích updatable.

```sql
-- SQL Server: INSERT từ CTE
;WITH src AS (
    SELECT CustomerId, SUM(Total) AS Total
    FROM dbo.Staging
    GROUP BY CustomerId
)
INSERT INTO dbo.DailyRev (CustomerId, Total)
SELECT CustomerId, Total FROM src;

;WITH m AS (
    SELECT * FROM dbo.Staging
)
MERGE dbo.Orders AS o
USING m ON o.Id = m.Id
WHEN MATCHED THEN UPDATE SET Total = m.Total
WHEN NOT MATCHED THEN INSERT (Id, Total) VALUES (m.Id, m.Total);

-- PostgreSQL: INSERT…SELECT + data-modifying CTE
WITH src AS (
    SELECT customer_id, sum(total) AS total
    FROM staging
    GROUP BY customer_id
)
INSERT INTO daily_rev (customer_id, total)
SELECT customer_id, total FROM src;

WITH upserted AS (
    INSERT INTO orders (id, total)
    SELECT id, total FROM staging
    ON CONFLICT (id) DO UPDATE SET total = EXCLUDED.total
    RETURNING id
)
UPDATE staging s SET synced_at = now()
FROM upserted u
WHERE s.id = u.id;
```

`ON CONFLICT DO SELECT` (PG **19**) trả hàng đã có, không ghi — [dml.md](dml.md). Không giả CTE làm snapshot chống race dưới READ COMMITTED.

CTE + `INSERT…SELECT` SS: `IDENTITY` / `OUTPUT` trên câu `INSERT` ngoài, không trên định nghĩa CTE.

---

## 16. Best practices & checklist

- Scalar: bảo đảm 0–1 hàng (`UNIQUE` / `MAX` / `TOP 1` + `ORDER BY` đủ khóa).
- Anti-join: `NOT EXISTS`, không `NOT IN` nullable.
- T-SQL: `;` trước `WITH` trong batch.
- Đệ quy: điều kiện `depth`; PG `CYCLE`; SS `MAXRECURSION` khớp trần (tránh `0` mù).
- Path biến độ dài: recursive CTE, không SQL/PGQ 19 `{1,n}`.
- Không forward-ref CTE; không `ORDER BY` trong CTE trừ khi `TOP`/`LIMIT`.
- Nhiều tham chiếu + đắt / volatile → PG `MATERIALIZED` hoặc `#temp`.
- `DELETE FROM cte` SS: hiểu là xóa base — tên CTE trong review phải rõ.
- PG DML CTE: chỉ tin `RETURNING`, không tin “chạy xong mới tới nhánh sau”.
- `LATERAL`/`APPLY`: `LEFT`/`OUTER` khi phải giữ hàng trái.

```text
□ ;WITH trong batch T-SQL
□ EXISTS/NOT EXISTS thay IN/NOT IN nullable
□ RECURSIVE keyword đúng dialect
□ CYCLE hoặc MAXRECURSION + depth
□ Không GRAPH_TABLE cho path {1,4} trên PG 19
□ MATERIALIZED / temp khi CTE 2 lần + đắt
□ LATERAL/APPLY CROSS vs OUTER
□ Scalar subquery unique
□ DML CTE: RETURNING / OUTPUT, không đọc bảng song song
```

---

## 17. Bẫy khi review

- Thiếu `;` trước `WITH` (SS).
- `WITH t AS (…)` không `RECURSIVE` trên PG rồi tự join `t`.
- `UNION` vs `UNION ALL` đệ quy — mất hàng hoặc không chặn vòng.
- Recursive SS dùng `LEFT JOIN` / `GROUP BY` / `DISTINCT`.
- `MAXRECURSION 0` trên dữ liệu user.
- Tin `max_recursion_depth` GUC (không có).
- `SEARCH` như “engine duyệt DFS” (chỉ cột sort).
- CTE hai lần = “chạy một lần” trên SS.
- `NOT MATERIALIZED` trên CTE recursive (bị ignore).
- `DELETE FROM cte` nghĩ xóa biến.
- Data-modifying CTE PG đọc bảng vừa sửa ở nhánh song song.
- Nested `WITH` trong CTE (SS).
- `ORDER BY` trong CTE không `TOP` rồi `FETCH` ngoài như đã sắp.
- `SELECT *` CTE + `ALTER TABLE ADD` — caller không thấy cột mới nếu đã list cột.
- Scalar >1 hàng chỉ vỡ production.
- `IN (SELECT col)` col nullable + `NOT IN`.
- `CROSS APPLY` nuốt hàng trái.
- `OFFSET` phân trang trong CTE thay keyset — [window-functions.md](window-functions.md).
- `GRAPH_TABLE` thay recursive path biến độ dài.
- SQL Graph SS `MATCH` copy sang PGQ.
- `MERGE` + CTE như snapshot dưới RC.
- `DISTINCT` trên recursive member SS.
- Đi lên cây nhưng join vẫn `parent_id = walk.id` (sai hướng).

---

## 18. Version gates

| Mục | SQL Server | PostgreSQL |
|---|---|---|
| CTE không đệ quy | 2005+ | lõi |
| Recursive CTE | 2005+ (không chữ `RECURSIVE`) | `WITH RECURSIVE` |
| `MAXRECURSION` | lõi (default 100) | — |
| `CYCLE` / `SEARCH` | — | **14+** |
| `AS MATERIALIZED` / `NOT MATERIALIZED` | — | **12+** |
| DML trong `WITH` + `RETURNING` | — (`OUTPUT` tách) | lõi |
| `DELETE`/`UPDATE` *tên* CTE | có (updatable) | dùng `USING` / DML CTE |
| `LATERAL` | `APPLY` | lõi |
| `IN` tuple `(a,b)` | — | lõi |
| Nested CTE trong CTE | không (warehouse Fabric: biến thể riêng) | subquery `WITH` được ở nhiều ngữ cảnh |
| SQL/PGQ `GRAPH_TABLE` path biến độ dài | SQL Graph khác (không PGQ) | **19 chưa có** — recursive CTE |

Routine chứa CTE / TVF + `MAXRECURSION`: [routines.md](routines.md). Isolation khi DML CTE: [transactions.md](transactions.md).

---

## Phụ lục A. CTE vs view vs temp

| Nhu cầu | Chọn | Không chọn |
|---|---|---|
| Một statement, đọc được bước | CTE | `#temp` (trừ khi re-execute / thống kê) |
| Tái sử dụng nhiều statement / session | View / TVF | CTE (hết statement là hết tên) |
| Index / stats / nhiều lần đọc khác predicate | `#temp` / table (PG) | CTE SS (re-execute); PG `MATERIALIZED` một statement |
| Đệ quy / `CYCLE` / `MAXRECURSION` | CTE recursive | view lồng view (cùng giới hạn, khó `OPTION`) |
| DML tập lọc `TOP`/`LIMIT` | CTE updatable (SS) / `USING` (PG) | derived không tên khi review dài |

View indexed SS / materialized view PG **không** phải CTE `MATERIALIZED`. Tên trùng chỉ là chữ.

Batch xóa: CTE + `TOP (1000)` trong vòng `WHILE @@ROWCOUNT > 0` (SS) hoặc loop `DELETE … RETURNING` (PG) — mỗi vòng một statement, không một recursive xóa.

`MERGE` nguồn CTE: vẫn race dưới RC nếu không khóa / `UPDLOCK` / `ON CONFLICT` — [dml.md](dml.md), [concurrency.md](concurrency.md).
