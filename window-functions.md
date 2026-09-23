# Window function

> **Baseline:** SQL Server **2025** · PostgreSQL **19**.  
> Window tính trên **partition** của hàng đã lọc (`WHERE` / `GROUP BY` / `HAVING`), **không** gộp mất hàng — khác aggregate thường.

Window không phải “GROUP BY giữ cột”. Mỗi hàng thấy một *khung* hàng liên quan theo `PARTITION BY` + `ORDER BY` + frame (`ROWS` / `RANGE` / `GROUPS`). Cùng `SUM(total) OVER (ORDER BY dt)` trên hai engine **khác nhau** nếu trùng khóa sắp — vì mặc định frame là `RANGE … CURRENT ROW` (gộp peer). File này là ngữ nghĩa frame, offset, phân trang; không phải catalog mọi hàm analytic.

Logical processing: [select.md](select.md). Aggregate không window: [functions.md](functions.md). CTE bọc window: [cte-subqueries.md](cte-subqueries.md).

---

## Mục lục

- [1. Tổng quan \& triết lý](#1-tổng-quan--triết-lý)
- [2. Cú pháp \& thứ tự logic](#2-cú-pháp--thứ-tự-logic)
- [3. Ranking](#3-ranking)
- [4. Offset](#4-offset)
- [5. Bẫy `LAST_VALUE`](#5-bẫy-last_value)
- [6. Aggregate làm window](#6-aggregate-làm-window)
- [7. Frame: `ROWS` / `RANGE` / `GROUPS`](#7-frame-rows--range--groups)
  - [7.1 `ROWS` vs `RANGE` vs peer](#71-rows-vs-range-vs-peer)
  - [7.2 `GROUPS` (PostgreSQL)](#72-groups-postgresql)
  - [7.3 `EXCLUDE` (PostgreSQL)](#73-exclude-postgresql)
- [8. Named `WINDOW`](#8-named-window)
- [9. `IGNORE NULLS`](#9-ignore-nulls)
  - [9.1 Cú pháp \& hàm](#91-cú-pháp--hàm)
  - [9.2 LOCF, gap, `NTH_VALUE`](#92-locf-gap-nth_value)
- [10. Phân trang: `ROW_NUMBER` vs keyset](#10-phân-trang-row_number-vs-keyset)
- [11. Gaps-and-islands](#11-gaps-and-islands)
- [12. Worked examples](#12-worked-examples)
- [13. Hàm nào nhìn frame](#13-hàm-nào-nhìn-frame)
- [14. `NULLS` trong `OVER` \& percentile](#14-nulls-trong-over--percentile)
- [15. Best practices \& checklist](#15-best-practices--checklist)
- [16. Bẫy khi review](#16-bẫy-khi-review)
- [17. Version gates](#17-version-gates)
- [Phụ lục A. Chaining named `WINDOW`](#phụ-lục-a-chaining-named-window)

---

## 1. Tổng quan & triết lý

Aggregate `GROUP BY` *thay* tập hàng bằng một hàng/nhóm. Window *giữ* hàng, gắn thêm cột tính từ hàng khác trong partition.

Ba trục độc lập:

1. **Partition** — “nhóm logic” (`PARTITION BY customer_id`). Thiếu = một partition toàn query.
2. **Thứ tự logic** — `ORDER BY` trong `OVER`, **không** phải thứ tự result set.
3. **Frame** — tập con partition mà hàm *phụ thuộc frame* nhìn (`SUM`, `AVG`, `FIRST_VALUE`, `LAST_VALUE`, `NTH_VALUE`). Ranking (`ROW_NUMBER`…) và `LAG`/`LEAD` **không** dùng frame dù có `ORDER BY`.

Chi phí: mỗi tổ hợp `PARTITION`/`ORDER` khác nhau có thể thêm một sort. Gộp named `WINDOW` khi cùng spec. Index `(partition_keys, order_keys)` giúp sequential scan theo window, không biến window thành seek thần kỳ.

`IGNORE NULLS` (SS **2022+**, PG **19**) chỉ đổi *hàng nào* hàm offset lấy — **không** sửa frame mặc định. `GROUPS` chỉ PostgreSQL. Đừng port một `OVER` sang engine kia rồi tin cùng số.

---

## 2. Cú pháp & thứ tự logic

```sql
fn(...) [FILTER (WHERE pred)] [IGNORE NULLS | RESPECT NULLS]
OVER (
    [PARTITION BY expr, ...]
    [ORDER BY expr [ASC|DESC] [NULLS FIRST|LAST], ...]
    [{ROWS | RANGE | GROUPS} BETWEEN frame_start AND frame_end
     [EXCLUDE {CURRENT ROW | GROUP | TIES | NO OTHERS}]]  -- EXCLUDE: PostgreSQL
)
```

`FILTER` trên window: **chỉ PostgreSQL**, và chỉ khi `fn` là aggregate. SQL Server: `SUM(CASE WHEN pred THEN x END) OVER (…)` — [functions.md](functions.md). `GROUPS` + `EXCLUDE`: **PostgreSQL**. SQL Server: `ROWS` / `RANGE` (RANGE hạn chế). `NULLS FIRST/LAST`: PG; SS theo `ASC` = NULLS FIRST, `DESC` = NULLS LAST (không sửa được bằng cú pháp `NULLS`).

Logical (rút gọn): window **sau** `HAVING`, **trước** `DISTINCT` / `ORDER BY` ngoài / `LIMIT`/`FETCH`. **Không** dùng window trong `WHERE` / `GROUP BY` / `HAVING`. Lọc `ROW_NUMBER = 1`: CTE / derived table.

```sql
WITH ranked AS (
    SELECT
        o.*,
        ROW_NUMBER() OVER (
            PARTITION BY customer_id
            ORDER BY created_at DESC, id DESC
        ) AS rn
    FROM orders AS o
)
SELECT * FROM ranked WHERE rn = 1;
```

**Ghi chú:** `SELECT DISTINCT` + window: `DISTINCT` chạy *sau* — thường không loại trùng theo ý “một hàng/nhóm”. Dùng `ROW_NUMBER` + lọc, hoặc `GROUP BY`.

---

## 3. Ranking

| Hàm | Ý nghĩa | Hòa (cùng ORDER BY) |
|---|---|---|
| `ROW_NUMBER()` | 1…n, không hòa | luôn khác nhau (thứ tự hòa **không xác định** nếu thiếu tiebreaker) |
| `RANK()` | cùng số, nhảy | 1, 1, 3 |
| `DENSE_RANK()` | cùng số, không nhảy | 1, 1, 2 |
| `NTILE(k)` | chia ~k nhóm | kích thước nhóm có thể lệch 1 |
| `PERCENT_RANK()` | `(rank-1)/(n-1)` | 0 khi n = 1 |
| `CUME_DIST()` | tỷ lệ hàng ≤ current | |

```sql
SELECT
    employee_id,
    dept_id,
    salary,
    ROW_NUMBER()  OVER (PARTITION BY dept_id ORDER BY salary DESC, employee_id) AS rn,
    RANK()        OVER (PARTITION BY dept_id ORDER BY salary DESC) AS rnk,
    DENSE_RANK()  OVER (PARTITION BY dept_id ORDER BY salary DESC) AS drnk,
    NTILE(4)      OVER (PARTITION BY dept_id ORDER BY salary DESC, employee_id) AS quartile
FROM employees;
```

Top-N mỗi nhóm: `ROW_NUMBER` + `WHERE rn <= N` (CTE). `RANK` giữ mọi người hòa — `TOP (3) WITH TIES` cùng ý theo *một* thứ tự toàn query, không phải per-group.

**Ghi chú:** `ROW_NUMBER` thiếu khóa unique trong `ORDER BY` → hàng hòa đổi chỗ giữa hai lần chạy. Pagination / “mới nhất mỗi khách” **bắt buộc** tiebreaker (`id`).

---

## 4. Offset

```sql
LAG(total, 1, 0)  OVER (PARTITION BY customer_id ORDER BY created_at, id)
LEAD(total)       OVER (ORDER BY created_at, id)
FIRST_VALUE(total) OVER (
    PARTITION BY customer_id
    ORDER BY created_at, id
    ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
)
NTH_VALUE(total, 2) OVER (                          -- PostgreSQL; SQL Server không có
    PARTITION BY customer_id
    ORDER BY created_at, id
    ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
)
```

`LAG(expr, offset, default)`: `offset` mặc định 1, không âm. Hết partition → `default` hoặc `NULL`. `LEAD` đối xứng tương lai.

SQL Server: `LAG`/`LEAD`/`FIRST_VALUE`/`LAST_VALUE` — không `NTH_VALUE`. PostgreSQL có đủ, kể cả `nth_value`.

Offset **không** nhìn frame. `LAG` hàng trước theo `ORDER BY`, bất kể `ROWS`. `IGNORE NULLS` trên `LAG` vẫn đi theo thứ tự logic, chỉ **nhảy** hàng NULL — §9.

---

## 5. Bẫy `LAST_VALUE`

### 5.0 Hình dung: cửa sổ mặc định chỉ nhìn *tới ghế mình*

`OVER (ORDER BY ngày)` không có nghĩa “cả nhóm khách”. Mặc định frame = từ đầu nhóm **đến hàng đang đứng**. `FIRST_VALUE` = người đầu hàng (thường đúng). `LAST_VALUE` = người *cuối cửa sổ* = **chính mình** (hoặc vài ghế cùng ngày nếu `RANGE`). Muốn “đơn cuối của khách” phải mở cửa sổ `UNBOUNDED FOLLOWING`.

```text
Hàng đang xử lý = ghế 2 trong hàng 4 ghế

  [1] [2] [3] [4]
   |___|          ← frame mặc định (đến CURRENT ROW)
        LAST_VALUE = ghế 2, không phải ghế 4
   |______________|  ← UNBOUNDED FOLLOWING
        LAST_VALUE = ghế 4
```

`IGNORE NULLS` chỉ nhảy ghế trống *trong cửa sổ đang mở* — không tự mở đến cuối nhóm.

Mặc định khi có `ORDER BY` mà **không** ghi frame, hàm phụ thuộc frame dùng:

```text
RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
```

`FIRST_VALUE` với mặc định này = giá trị hàng *đầu* (thường đúng ý). `LAST_VALUE` = giá trị *cuối frame* = **hàng hiện tại** (hoặc peer cùng khóa nếu `RANGE`) — **không** phải cuối partition.

Dữ liệu minh họa (một `customer_id`):

```text
id  created_at  total
1   2026-01-01  10
2   2026-01-02  20
3   2026-01-02  30     -- cùng ngày với hàng 2
4   2026-01-03  40
```

```sql
-- (A) SAI ý “total cuối nhóm” — mọi hàng ra chính total của hàng đó
SELECT id, total,
       LAST_VALUE(total) OVER (
           PARTITION BY customer_id
           ORDER BY created_at
       ) AS lv_default
FROM orders;
-- hàng 1 → 10; hàng 2 → 30 (RANGE gộp peer 2+3); hàng 3 → 30; hàng 4 → 40
-- Không hàng nào ra 40 trừ hàng cuối / peer cuối.

-- (B) ĐÚNG: nới frame đến hết partition, ROWS + tiebreaker
SELECT id, total,
       LAST_VALUE(total) OVER (
           PARTITION BY customer_id
           ORDER BY created_at, id
           ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
       ) AS last_in_partition          -- 40 trên mọi hàng
FROM orders;

-- (C) LAST_VALUE “tính đến hàng này” (running last) — frame đúng ý running
SELECT id, total,
       LAST_VALUE(total) OVER (
           PARTITION BY customer_id
           ORDER BY created_at, id
           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
       ) AS running_last               -- 10, 20, 30, 40
FROM orders;

-- (D) RANGE + trùng ngày: running last nhảy peer
SELECT id, total,
       LAST_VALUE(total) OVER (
           PARTITION BY customer_id
           ORDER BY created_at
           RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
       ) AS range_last                 -- hàng 2 đã thấy 30
FROM orders;

-- (E) Đảo thứ tự rồi FIRST_VALUE (đôi khi rẻ hơn tùy plan)
SELECT id, total,
       FIRST_VALUE(total) OVER (
           PARTITION BY customer_id
           ORDER BY created_at DESC, id DESC
           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
       ) AS last_via_first             -- 40
FROM orders;
```

`NTH_VALUE(x, 3)` với frame mặc định: hàng 1–2 **chưa** có hàng thứ 3 trong frame → `NULL` cho đến khi frame đủ. Cùng bẫy `LAST_VALUE`.

`IGNORE NULLS` **không** sửa (A). `LAST_VALUE(total) IGNORE NULLS OVER (ORDER BY created_at)` vẫn `CURRENT ROW` — nếu hàng hiện tại NULL thì nhảy NULL *trong frame hẹp*, không lấy cuối partition.

**Ghi chú:** Review thấy `LAST_VALUE` không `UNBOUNDED FOLLOWING` (và không `FIRST_VALUE` đảo) → gần như chắc sai nghiệp vụ “cuối nhóm”. Viết `ROWS` tường minh, đừng dựa mặc định `RANGE`.

---

## 6. Aggregate làm window

```sql
SUM(total) OVER (PARTITION BY customer_id)           -- tổng nhóm, lặp trên mọi hàng nhóm
SUM(total) OVER (                                    -- running total theo hàng
    PARTITION BY customer_id
    ORDER BY created_at, id
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
)
AVG(total) OVER (
    ORDER BY created_at
    ROWS BETWEEN 6 PRECEDING AND CURRENT ROW         -- 7 hàng (6 trước + hiện tại)
)
COUNT(*) OVER ()                                     -- số hàng result (sau WHERE/HAVING)
PRODUCT(1 + r) OVER (PARTITION BY instrument)        -- SS 2025; PG không có PRODUCT
```

`COUNT(*) OVER ()` để tính `%` mà không subquery. `SUM(x) / SUM(SUM(x)) OVER ()` sau `GROUP BY` = tỷ trọng nhóm.

Running total: **luôn** `ROWS` + tiebreaker. `RANGE` mặc định gộp peer cùng ngày → “nhảy” tổng khi nhiều đơn một ngày.

PostgreSQL:

```sql
SUM(total) FILTER (WHERE status = 'paid') OVER (PARTITION BY customer_id)
```

---

## 7. Frame: `ROWS` / `RANGE` / `GROUPS`

**Hình dung.** `ROWS` đếm **ghế**. `2 PRECEDING` = hai ghế ngay trước, dù cùng ngày hay khác ngày.

`RANGE` đếm **giá trị khóa**. Hai đơn cùng `created_at` là *cùng một nhóm bạn* (peer). Running sum `RANGE … CURRENT ROW` **cộng hết** đơn cùng ngày, không dừng ở “hàng đang đứng”. Hai hàng cùng ngày có thể ra **cùng** tổng — hay bị tưởng bug.

`GROUPS` (chỉ PostgreSQL) đếm **nhóm peer**: “một nhóm ngày trước”, không phải “một hàng”.

```text
Ngày:  1   1   2        qty 10, 20, 5
ROWS 1 PRECEDING của hàng thứ hai: chỉ ghế trước (10) + mình
RANGE CURRENT ROW: cả hai hàng ngày 1 (10+20) vì cùng khóa
```

```text
ROWS   BETWEEN 2 PRECEDING AND CURRENT ROW     -- đúng 3 hàng (nếu đủ)
RANGE  BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW   -- + mọi peer cùng ORDER BY
GROUPS BETWEEN 1 PRECEDING AND CURRENT ROW     -- PG: nhóm peer trước + nhóm hiện tại
```

| Mode | “1 PRECEDING” nghĩa là | SQL Server | PostgreSQL |
|---|---|---|---|
| `ROWS` | một **hàng** trước | có | có |
| `RANGE` | một **giá trị** offset trên *một* cột ORDER BY | chỉ `UNBOUNDED` / `CURRENT ROW` — **không** `RANGE BETWEEN 1 PRECEDING` / interval | có; datetime dùng `interval` |
| `GROUPS` | một **nhóm peer** trước | **không** | có (SQL:2011) |

Không `ORDER BY` trong `OVER`: frame = **cả partition** (với hàm nhận frame).

Có `ORDER BY`, không ghi `ROWS`/`RANGE`/`GROUPS`: mặc định `RANGE UNBOUNDED PRECEDING … CURRENT ROW`.

### 7.1 `ROWS` vs `RANGE` vs peer

Peer: hai hàng *bằng nhau* trên mọi biểu thức `ORDER BY`. `RANGE … CURRENT ROW` gồm **cả** peer sau hàng hiện tại trong thứ tự vật lý — running sum không “dừng ở hàng này”.

```sql
-- PostgreSQL: 7 ngày lịch, không phải 7 hàng
SUM(qty) OVER (
    ORDER BY d
    RANGE BETWEEN INTERVAL '6 days' PRECEDING AND CURRENT ROW
)

-- SQL Server: không viết được RANGE interval. Gần đúng bằng ROWS chỉ khi đúng 1 hàng/ngày.
-- Đúng nghĩa 7 ngày: self-join / CROSS APPLY / CTE ngày, không giả RANGE.
```

**Ghi chú:** Moving average “N ngày” ≠ `ROWS BETWEEN N PRECEDING`. Thiếu ngày = thiếu hàng; `ROWS` kéo ngày xa hơn N. Dùng `RANGE` + `interval` (PG) hoặc bảng calendar.

### 7.2 `GROUPS` (PostgreSQL)

`GROUPS` đếm **nhóm peer**, không hàng, không giá trị. Một nhóm = tập hàng bằng nhau trên `ORDER BY`.

```sql
-- PostgreSQL — không có trên SQL Server
-- 1 PRECEDING = cả nhóm peer *trước* (mọi hàng cùng khóa trước đó), không chỉ 1 hàng
SUM(qty) OVER (
    ORDER BY d
    GROUPS BETWEEN 1 PRECEDING AND CURRENT ROW
)
```

Ví dụ: ngày `d` với 1, 5, 2 hàng (ba nhóm). Tại hàng đầu nhóm thứ ba, `GROUPS 1 PRECEDING … CURRENT ROW` = mọi hàng nhóm 2 **và** nhóm 3 — không phải “một hàng trước”.

`GROUPS UNBOUNDED PRECEDING AND CURRENT ROW` gần `RANGE … CURRENT ROW` khi peer định nghĩa giống nhau; khác `ROWS` khi nhóm dày.

Port sang SQL Server: không có `GROUPS`. Xấp xỉ:

- Grain 1 hàng / khóa: `ROWS` ≡ `GROUPS`.
- Nhiều hàng / khóa: dense-rank làm “số nhóm” rồi frame `ROWS` trên *nhóm đã gộp*, hoặc self-join theo `DENSE_RANK`.

```sql
-- SQL Server: moving sum theo 2 *giá trị ngày* (nhóm), không 2 hàng
WITH s AS (
    SELECT
        d, qty,
        DENSE_RANK() OVER (ORDER BY d) AS grp
    FROM dbo.Daily
)
SELECT
    d, qty,
    SUM(qty) OVER (
        ORDER BY grp
        ROWS BETWEEN 1 PRECEDING AND CURRENT ROW   -- vẫn theo HÀNG đã đánh số, không phải nhóm
    )
FROM s;
```

Cách trên **vẫn** `ROWS` theo hàng — sai nếu một ngày nhiều hàng. Đúng nghĩa `GROUPS`: gộp theo `d` trước, rồi window trên aggregate; hoặc join `DENSE_RANK` hiện tại với `DENSE_RANK` ∈ [cur-1, cur].

```sql
-- Ý GROUPS 1 PRECEDING: tổng qty các ngày (d-1 và d), mọi hàng cùng ngày
WITH x AS (
    SELECT d, qty, DENSE_RANK() OVER (ORDER BY d) AS g
    FROM daily
)
SELECT
    a.d, a.qty,
    SUM(b.qty) AS grp_window
FROM x AS a
JOIN x AS b ON b.g BETWEEN a.g - 1 AND a.g
GROUP BY a.d, a.qty, a.g;          -- cẩn thận grain; thường gộp x trước
```

Cú pháp biên đầy đủ (PG; SS subset): `UNBOUNDED PRECEDING` | `n PRECEDING` | `CURRENT ROW` | `n FOLLOWING` | `UNBOUNDED FOLLOWING`. `n` không âm. Frame `FOLLOWING` trước `PRECEDING` → lỗi. `RANGE` + `n PRECEDING` trên PG cần đúng *một* cột `ORDER BY` kiểu có phép cộng (số / datetime + interval).

Đừng bịa `GROUPS` trên T-SQL.
### 7.3 `EXCLUDE` (PostgreSQL)

```sql
AVG(v) OVER (
    ORDER BY ts
    ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING
    EXCLUDE CURRENT ROW          -- khung 2 hàng kề, bỏ mình
)
-- EXCLUDE GROUP  : bỏ cả peer group của hàng hiện tại
-- EXCLUDE TIES   : bỏ peer khác, giữ hàng hiện tại
-- EXCLUDE NO OTHERS : mặc định
```

SQL Server không có. Trung bình “hàng kề không kể mình”: `(LAG(v)+LEAD(v))/2` hoặc `SUM(v) OVER (ROWS 1 PRECEDING AND 1 FOLLOWING) - v`.

---

## 8. Named `WINDOW`

Cả hai engine: mệnh đề `WINDOW` (SQL Server **2022+**; PostgreSQL lõi). Tên là identifier. Cửa sổ sau *tham chiếu* cửa sổ trước — thêm `ORDER BY` / frame, **không** được đổi `PARTITION BY` đã có.

```sql
-- Cả hai (SS 2022+, PG)
SELECT
    id,
    SUM(n)  OVER w     AS running,
    AVG(n)  OVER w     AS moving,
    LAG(n)  OVER w_ord AS prev,
    LAST_VALUE(n) OVER w_full AS last_in_part
FROM t
WINDOW
    w_ord  AS (PARTITION BY grp ORDER BY id),
    w      AS (w_ord ROWS BETWEEN 2 PRECEDING AND CURRENT ROW),
    w_full AS (w_ord ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING);
```

Một chỗ sửa frame — mọi hàm `OVER w` theo. Tránh copy-paste một chỗ `UNBOUNDED FOLLOWING`, chỗ kia quên (§5).

SQL Server cũng cho dạng bổ sung partition lên tên đã định (`OVER (win PARTITION BY …)`) trên một số ngữ cảnh — đối chiếu Learn; khi nghi ngờ viết `OVER (…)` đủ một chỗ hoặc chỉ `WINDOW` + tham chiếu.

Không đặt `WINDOW` trong view/inline TVF rồi gọi từ ngoài như biến — phạm vi **một** `SELECT`. CTE: mỗi tầng `SELECT` một danh sách `WINDOW`.

Plan vẫn có thể sort một lần nếu spec trùng, kể cả không đặt tên. Tên là công cụ đọc/review, không hint optimizer.

**Ghi chú:** Named window trên SS 2019 = lỗi cú pháp. Port PG → SS 2019: bung từng `OVER (PARTITION BY … ORDER BY … ROWS …)` đầy đủ.

---

## 9. `IGNORE NULLS`

Mặc định `RESPECT NULLS`: `LAG` thấy NULL nếu hàng trước NULL.

### 9.1 Cú pháp & hàm

Clause **sau** ngoặc hàm, trước `OVER` — SQL standard. Không phải Oracle `LAG(value IGNORE NULLS)`.

```sql
-- Cả hai: SS 2022+, PG 19
SELECT
    ts,
    value,
    LAG(value) IGNORE NULLS OVER (ORDER BY ts) AS last_non_null,
    LEAD(value) IGNORE NULLS OVER (ORDER BY ts) AS next_non_null
FROM series;
```

| | SQL Server | PostgreSQL |
|---|---|---|
| Có từ | **2022+** | **19** (không có trên 18) |
| Hàm | `FIRST_VALUE` `LAST_VALUE` `LAG` `LEAD` | `first_value` `lag` `lead` `last_value` **`nth_value`** |
| `NTH_VALUE … IGNORE NULLS` | không có hàm | **19** |

Chuỗi:

```text
ts    value
09:00  10
10:00  NULL
11:00  NULL
12:00  20
```

`LAG(value) OVER (ORDER BY ts)` tại 12:00 = **NULL** (hàng 11:00).  
`LAG(value) IGNORE NULLS …` tại 12:00 = **10**.  
`LEAD(value) IGNORE NULLS` tại 09:00 = **20**.

PG 18- : CTE + `LAG` lọc NULL, hoặc `last_value` thủ công — đừng copy `IGNORE NULLS` xuống 18.

### 9.2 LOCF, gap, `NTH_VALUE`

```sql
-- Last observation carried forward — FRAME vẫn CURRENT ROW
LAST_VALUE(value) IGNORE NULLS OVER (
    ORDER BY ts
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
)
```

Tại 10:00 và 11:00: `LAST_VALUE` + `IGNORE NULLS` + frame đến hiện tại = 10. Thiếu `IGNORE NULLS` = NULL. Thiếu nới frame nhưng thêm `UNBOUNDED FOLLOWING` = 20 trên *mọi* hàng (cuối partition), không phải LOCF.

```sql
-- SAI: IGNORE NULLS không cứu frame mặc định LAST_VALUE
LAST_VALUE(value) IGNORE NULLS OVER (ORDER BY ts)
-- RANGE … CURRENT ROW: hàng NULL → NULL (không có non-null *sau* mình trong frame)

-- PostgreSQL 19: giá trị non-null thứ 2 trong frame đủ rộng
NTH_VALUE(value, 2) IGNORE NULLS OVER (
    ORDER BY ts
    ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
)
```

SQL Server: không `NTH_VALUE`. Lấy “non-null thứ N”: đánh số `SUM(CASE WHEN value IS NOT NULL THEN 1 END) OVER (… ROWS UNBOUNDED PRECEDING)` rồi lọc, hoặc `ROW_NUMBER` trên tập đã lọc NULL.

`RESPECT NULLS` viết tường minh khi review cần thấy cố ý giữ NULL — mặc định đã vậy.

**Ghi chú:** `IGNORE NULLS` + `LAST_VALUE` **vẫn** cần frame đúng (§5). Không viết `LAG(value IGNORE NULLS)`.

---

## 10. Phân trang: `ROW_NUMBER` vs keyset

```sql
-- Offset (đơn giản, đắt ở trang sâu)
SELECT *
FROM orders
ORDER BY created_at DESC, id DESC
OFFSET 20 ROWS FETCH NEXT 20 ROWS ONLY;      -- SS / PG (SS: không trộn TOP)

-- Tương đương logic: đánh số rồi lọc — vẫn sort/scan phần đầu
SELECT *
FROM (
    SELECT o.*, ROW_NUMBER() OVER (ORDER BY created_at DESC, id DESC) AS rn
    FROM orders AS o
) s
WHERE rn BETWEEN 21 AND 40;
```

Keyset (seek, ổn định khi có insert xen):

```sql
-- PostgreSQL: so sánh tuple
SELECT *
FROM orders
WHERE (created_at, id) < (@last_at, @last_id)
ORDER BY created_at DESC, id DESC
FETCH FIRST 20 ROWS ONLY;

-- SQL Server: chưa có so sánh tuple; mở rộng
SELECT TOP (20) *
FROM dbo.Orders
WHERE created_at < @last_at
   OR (created_at = @last_at AND id < @last_id)
ORDER BY created_at DESC, id DESC;
```

Index `(created_at DESC, id DESC)`. Tiebreaker **unique**. Trang theo `OFFSET 100000` trên OLTP = incident latency. `ROW_NUMBER` toàn bảng rồi `WHERE rn` cùng hạng — đừng dùng cho infinite scroll.

Top-N *mỗi nhóm* (mới nhất mỗi khách): window hoặc `APPLY`/`LATERAL` + `TOP`/`LIMIT` 1 — [joins.md](joins.md), [select.md](select.md). Nhiều khách, ít hàng/nhóm: `LATERAL` + index thường thắng `ROW_NUMBER` toàn bảng.

**Ghi chú:** Keyset không cho “nhảy tới trang 50” trừ khi giữ stack cursor. UI số trang + bảng lớn: chấp nhận OFFSET có trần, hoặc cursor opaque.

---

## 11. Gaps-and-islands

Bài: gộp hàng *liền kề* (theo thứ tự) thành đoạn. Công thức cổ điển: hiệu giữa thuộc tính tăng đều và `ROW_NUMBER`.

**Đảo ngày liên tiếp** (lịch, không lỗ):

```sql
-- PostgreSQL
SELECT
    MIN(d) AS start_d,
    MAX(d) AS end_d,
    COUNT(*) AS days
FROM (
    SELECT
        d,
        d - (ROW_NUMBER() OVER (ORDER BY d)) * INTERVAL '1 day' AS grp
    FROM days
) s
GROUP BY grp;

-- SQL Server
SELECT
    MIN(d) AS start_d,
    MAX(d) AS end_d,
    COUNT(*) AS days
FROM (
    SELECT
        d,
        DATEADD(day, -ROW_NUMBER() OVER (ORDER BY d), d) AS grp
    FROM dbo.Days
) s
GROUP BY grp;
```

**Đảo trạng thái** (cùng `status` liên tiếp theo thời gian, mỗi khách):

```sql
SELECT
    customer_id,
    status,
    MIN(ts) AS start_ts,
    MAX(ts) AS end_ts
FROM (
    SELECT
        customer_id,
        status,
        ts,
        ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY ts)
      - ROW_NUMBER() OVER (PARTITION BY customer_id, status ORDER BY ts) AS island
    FROM events
) s
GROUP BY customer_id, status, island;
```

Hai `ROW_NUMBER` lệch nhau đúng khi `status` đổi — `island` constant trong một run. Thêm `id` vào `ORDER BY` nếu `ts` trùng.

Biến thể: `LAG(status)` + cờ “đổi” + `SUM(cờ) OVER (ORDER BY … ROWS …)` tạo island id — dễ đọc, thêm một pass.

**Ghi chú:** Công thức ngày giả định **grain một ngày / hàng**. Hai hàng một ngày phá `d - rn`. Trước khi gộp: `SELECT DISTINCT d` hoặc grain đúng.

---

## 12. Worked examples

**Running vs partition last trên cùng named window**

```sql
SELECT
    customer_id,
    created_at,
    total,
    SUM(total) OVER w_run AS running,
    LAST_VALUE(total) OVER w_run AS last_so_far,
    LAST_VALUE(total) OVER w_all AS last_of_customer
FROM orders
WINDOW
    w_base AS (PARTITION BY customer_id ORDER BY created_at, id),
    w_run  AS (w_base ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW),
    w_all  AS (w_base ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING);
```

SS 2022+ / PG. `last_so_far` ≠ `last_of_customer` trừ hàng cuối.

**LOCF + LEAD non-null (cảm biến)**

```sql
SELECT
    sensor_id,
    ts,
    reading,
    LAST_VALUE(reading) IGNORE NULLS OVER w AS filled,
    LEAD(reading) IGNORE NULLS OVER w_ord AS next_known
FROM readings
WINDOW
    w_ord AS (PARTITION BY sensor_id ORDER BY ts),
    w     AS (w_ord ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW);
```

PG **19** và SS **2022+**. Bản PG 18: không clause này.

**Peer RANGE làm running total nhảy**

```text
dt          amount
2026-01-01  10
2026-01-02  20
2026-01-02  5
2026-01-03  40
```

```sql
SUM(amount) OVER (ORDER BY dt)                               -- mặc định RANGE
-- 10 | 35 | 35 | 75     — hai hàng 01-02 cùng tổng 35
SUM(amount) OVER (ORDER BY dt, id ROWS UNBOUNDED PRECEDING)  -- 10 | 30 | 35 | 75
```

**GROUPS vs ROWS trên doanh thu theo ngày**

```sql
-- PostgreSQL: tổng ngày hiện tại + ngày (nhóm) trước, mọi đơn trong hai ngày đó
SELECT
    order_id, d, amount,
    SUM(amount) OVER (
        ORDER BY d
        GROUPS BETWEEN 1 PRECEDING AND CURRENT ROW
    ) AS two_day_groups
FROM orders;

-- Sai nếu viết ROWS 1 PRECEDING khi một ngày 50 đơn — chỉ lấy 2 hàng.
```

---

## 13. Hàm nào nhìn frame

Không phải mọi hàm trong `OVER` dùng frame. Review nhầm `ROWS` trên `LAG` như thể đổi offset.

| Nhìn frame? | Hàm |
|---|---|
| **Không** | `ROW_NUMBER` `RANK` `DENSE_RANK` `NTILE` `PERCENT_RANK` `CUME_DIST` `LAG` `LEAD` |
| **Có** | `SUM` `AVG` `COUNT` `MIN` `MAX` `PRODUCT` (SS) `FIRST_VALUE` `LAST_VALUE` `NTH_VALUE` (PG) và aggregate-as-window khác |

`LAG`/`LEAD` đi theo `ORDER BY` + offset hàng (và `IGNORE NULLS` nếu có). Viết `LAG(x) OVER (ORDER BY ts ROWS BETWEEN 5 PRECEDING AND CURRENT ROW)` — `ROWS` **bị bỏ qua** (không đổi nghĩa offset). `FIRST_VALUE` *có* nhìn frame.

`COUNT(*) OVER ()` không `ORDER BY` = cả partition (mọi hàng sau `WHERE`/`HAVING`). `COUNT(*) OVER (ORDER BY ts)` = mặc định `RANGE … CURRENT ROW` = số hàng *đến peer hiện tại*, không phải tổng partition.

Window + `DISTINCT` trong hàm: `COUNT(DISTINCT x) OVER (…)` — SQL Server **không** hỗ trợ (lỗi cú pháp). PostgreSQL: `COUNT(DISTINCT)` window hạn chế — thường gộp trước hoặc `dense_rank`. Đừng bịa `SUM(DISTINCT) OVER` trên SS.

---

## 14. `NULLS` trong `OVER` & percentile

```sql
-- PostgreSQL: NULLS LAST khi xếp lương (NULL = chưa gán, đẩy cuối)
ROW_NUMBER() OVER (PARTITION BY dept ORDER BY salary DESC NULLS LAST, id)

-- SQL Server: không cú pháp NULLS FIRST/LAST.
-- ASC  → NULL trước (NULLS FIRST)
-- DESC → NULL sau  (NULLS LAST)
-- Ép: ORDER BY CASE WHEN salary IS NULL THEN 1 ELSE 0 END, salary DESC, id
```

`PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY total) OVER (PARTITION BY dept)` — SQL Server: **window**, giữ hàng, bắt buộc `OVER`. PostgreSQL `percentile_cont` là **ordered-set aggregate** (gộp hàng); ordered-set *window* được nhưng khác hợp đồng SS (SS giữ mọi hàng cùng percentile). Port median: đọc [functions.md](functions.md) §6 — đừng copy `WITHIN GROUP` PG vào SS rồi quên `OVER`.

`PERCENT_RANK` / `CUME_DIST` không dùng frame; hòa theo `ORDER BY` như `RANK`. `n = 1` → `PERCENT_RANK` = 0.

---

## 15. Best practices & checklist

- Tiebreaker unique trong mọi `ORDER BY` của ranking / running / pagination.
- Frame: viết `ROWS BETWEEN …` tường minh cho running total và `LAST_VALUE`.
- `RANGE` chỉ khi *cố ý* gộp peer; SS không có `RANGE` interval.
- `GROUPS` / `EXCLUDE` / `FILTER` window: PG — port sang SS bằng gộp grain / `DENSE_RANK` / `CASE`.
- Named `WINDOW` khi ≥2 hàm cùng spec (SS 2022+).
- `IGNORE NULLS` cho chuỗi thời gian thưa (SS 2022+, PG **19**).
- Phân trang API: keyset; `OFFSET` chỉ trang nông / admin.
- Gaps-and-islands: grain trước, rồi `ROW_NUMBER`.
- Index khớp `(PARTITION BY keys, ORDER BY keys INCLUDE …)`.
- Không window trong `WHERE`; CTE rõ ràng hơn subquery lồng ba tầng.

```text
□ OVER có ORDER BY đủ khóa
□ LAST_VALUE có UNBOUNDED FOLLOWING (hoặc FIRST_VALUE đảo) nếu ý là cuối nhóm
□ Running SUM dùng ROWS không RANGE mặc định
□ IGNORE NULLS đúng dialect/phiên bản (PG 19, không 18)
□ GROUPS không copy sang T-SQL
□ Pagination không OFFSET sâu
□ Island GROUP BY gồm đúng khóa island
□ WINDOW named cùng PARTITION khi reference
```

---

## 16. Bẫy khi review

- Window trong `WHERE` — lỗi parse.
- `DISTINCT` + window như “unique partition”.
- `ORDER BY` trong `OVER` bị hiểu là thứ tự output.
- `LAST_VALUE` không sửa frame.
- `LAST_VALUE … IGNORE NULLS` nghĩ đã lấy cuối partition.
- `RANGE` vs `ROWS` khi trùng ngày — running total nhảy.
- `ROWS BETWEEN 6 PRECEDING` gọi là “7 ngày”.
- `GROUPS 1 PRECEDING` gọi là “một hàng trước”.
- `LAG` mong “giá trị khác NULL trước đó” mà không `IGNORE NULLS`.
- `NTILE` như quartile thống kê chặt (nó chia count, không percentile).
- `ROW_NUMBER` phân trang sâu trên 10⁸ hàng.
- Thiếu tiebreaker → test flaky.
- Copy `GROUPS` / `EXCLUDE` / `NTH_VALUE` / `FILTER` sang SQL Server.
- Copy `IGNORE NULLS` sang PG 18- (chỉ **19**).
- Named `WINDOW` trên SS 2019 (cần 2022+).
- `PERCENT_RANK` với n = 1 (0) hiểu nhầm.
- Sort lặp: năm cửa sổ `ORDER BY` khác nhau trên cùng CTE nặng.
- `LAG(x IGNORE NULLS)` Oracle-style.
- `ROWS` trên `LAG` nghĩ đổi offset.
- `COUNT(*) OVER (ORDER BY …)` nghĩ là tổng partition.
- `COUNT(DISTINCT x) OVER` trên SQL Server.
- `NULLS LAST` copy sang T-SQL.

---

## 17. Version gates

| Mục | SQL Server | PostgreSQL |
|---|---|---|
| `ROW_NUMBER` / `RANK` / `LAG` / `SUM() OVER` | lõi (2005/2012 tùy hàm) | lõi |
| `ROWS` frame `n PRECEDING` | có | có |
| `RANGE` + interval / `n PRECEDING` | **không** (chỉ UNBOUNDED/CURRENT ROW) | có |
| `GROUPS` frame | — | lõi (SQL:2011) |
| `EXCLUDE` frame | — | lõi |
| Named `WINDOW` | **2022+** | lõi |
| `IGNORE NULLS` / `RESPECT NULLS` | **2022+** (`LAG`/`LEAD`/`FIRST_VALUE`/`LAST_VALUE`) | **19** (+ `nth_value`) |
| `NTH_VALUE` | — | lõi |
| `FILTER` trên window aggregate | — | lõi |
| `PRODUCT() OVER` | **2025** | — |
| `NULLS FIRST` / `LAST` trong `OVER` | — | lõi |
| So sánh tuple keyset `(a,b) < (…)` | — | lõi |

`TOP`/`FETCH`: [select.md](select.md). Hàm `PRODUCT` / `FILTER`: [functions.md](functions.md).

---

## Phụ lục A. Chaining named `WINDOW`

Cả SS 2022+ và PG: `WINDOW w2 AS (w1 …)` copy `PARTITION BY` (và `ORDER BY` nếu `w1` đã có) rồi **chỉ được thêm** phần còn thiếu — `ORDER BY` nếu chưa có, rồi frame.

```sql
WINDOW
    w_part AS (PARTITION BY customer_id),
    w_ord  AS (w_part ORDER BY created_at, id),
    w_run  AS (w_ord ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW);
```

Cấm: `WINDOW w2 AS (w1 PARTITION BY other)` khi `w1` đã có partition — đổi tập nhóm. Cấm hai `ORDER BY` chồng (thay, không merge). Frame trên `w1` rồi `w2` thêm frame khác → lỗi / không portable; để frame ở cửa sổ *lá*.

`OVER w_run` và `OVER (w_run)` cùng nghĩa khi tên đủ. Ranking (`ROW_NUMBER`) trên `w_run` **bỏ qua** frame — vẫn hữu ích vì cùng `PARTITION`/`ORDER` với `SUM` running, một spec.

SQL Server 2019-: bung từng `OVER (` đầy đủ. PG mọi bản lõi có `WINDOW`.
