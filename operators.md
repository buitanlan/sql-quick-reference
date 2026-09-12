# Toán tử (Operators)

> **Baseline:** SQL Server **2025** · PostgreSQL **19**.  
> Precedence không giống C# / C. Khi nghi ngờ — **dùng ngoặc**.

Toán tử SQL gắn với *kiểu* và *three-valued logic*, không với method overload kiểu C#. `=` vừa so sánh vừa (T-SQL) gán trong `SET`; `+` vừa cộng vừa nối chuỗi trên SQL Server; PostgreSQL `^` là lũy thừa, `#` mới là XOR. Optimizer **được** đổi thứ tự `AND`/`OR` — không có short-circuit chuẩn. File này là ngữ nghĩa để review, không phải bảng ghi nhớ một dòng.

Kiểu toán hạng: [typesystem.md](typesystem.md). NULL / `UNKNOWN`: [dialects.md](dialects.md). JSON sâu: [json.md](json.md).

`IGNORE NULLS` / `RESPECT NULLS` là **clause window**, không toán tử infix — [window-functions.md](window-functions.md), [keywords.md](keywords.md). Không nhét vào `WHERE`.

---

## Mục lục

- [1. Tổng quan \& triết lý](#1-tổng-quan--triết-lý)
- [2. Precedence](#2-precedence)
- [3. Số học](#3-số-học)
  - [3.1 Chia nguyên \& modulo](#31-chia-nguyên--modulo)
  - [3.2 Lũy thừa vs XOR](#32-lũy-thừa-vs-xor)
  - [3.3 `PRODUCT()`](#33-product)
- [4. So sánh](#4-so-sánh)
  - [4.1 `BETWEEN`, `IN`](#41-between-in)
  - [4.2 `ALL` / `ANY` / `SOME`](#42-all--any--some)
- [5. Logic \& three-valued](#5-logic--three-valued)
- [6. Chuỗi](#6-chuỗi)
- [7. `LIKE` / `SIMILAR` / regex](#7-like--similar--regex)
- [8. NULL-safe](#8-null-safe)
- [9. Tập hợp](#9-tập-hợp)
- [10. JSON](#10-json)
- [11. Array / range / overlap](#11-array--range--overlap)
- [12. Bit](#12-bit)
- [13. Vector \& fuzzy](#13-vector--fuzzy)
- [14. Gán \& compound (T-SQL)](#14-gán--compound-t-sql)
- [15. Overload (PostgreSQL)](#15-overload-postgresql)
- [16. Hai session — ví dụ làm việc](#16-hai-session--ví-dụ-làm-việc)
- [17. Best practices \& checklist](#17-best-practices--checklist)
- [18. Bẫy khi review](#18-bẫy-khi-review)
- [19. Version gates](#19-version-gates)
- [Phụ lục A. `REGEXP_LIKE` vs infix](#phụ-lục-a-regexp_like--hàm-vs-infix-flags)
- [Phụ lục B. `JSON_CONTAINS` vs `@>`](#phụ-lục-b-json_contains-vs--vs-json_value)
- [Phụ lục C. `LIKE ESCAPE`](#phụ-lục-c-like-escape-hai-session)
- [Phụ lục D. Vector distance](#phụ-lục-d-vector-distance--hàm-vs-operator)
- [Phụ lục E. `FILTER` / `IGNORE NULLS`](#phụ-lục-e-filter--ignore-nulls--không-phải-toán-tử-đây)

---

## 1. Tổng quan & triết lý

- Kết quả so sánh là `TRUE` / `FALSE` / `UNKNOWN` — `WHERE` loại `UNKNOWN`.
- User-defined operator: PostgreSQL `CREATE OPERATOR`; SQL Server **không** (chỉ CLR function/aggregate).
- Spatial / full-text / vector dùng hàm hoặc operator extension (`<->` pgvector) — không nhầm với so sánh vô hướng.
- `+` T-SQL overload số vs chuỗi theo precedence kiểu — ép tường minh.

```sql
SELECT 1 + 2;                 -- 3
SELECT '1' + '2';             -- SQL Server: '12' (varchar+varchar)
-- PostgreSQL: '1' + '2' lỗi (không có text + text); dùng ||
```

**Ghi chú:** Regex SQL Server 2025 là **hàm** `REGEXP_LIKE` (GA), không infix `~`. Fuzzy `EDIT_DISTANCE` = **PREVIEW**. `JSON_CONTAINS` = hàm, **PREVIEW** on-prem. PG 19 fold `IS DISTINCT FROM NULL` là optimizer, không toán tử mới.

---

## 2. Precedence

Rút gọn (cao → thấp), gần ANSI + dialect:

1. `.` `[]` `::` (PG cast) `()`
2. Unary `+` `-` `~`
3. `*` `/` `%` — PostgreSQL `^` (lũy thừa) **rất chặt**, gần mức này
4. `+` `-` (binary)
5. `&` `^` `|` (bit; SQL Server — `^` là XOR)
6. So sánh: `=` `<>` `!=` `<` `>` `<=` `>=`
7. `IS [NOT]`, `IN`, `BETWEEN`, `LIKE`, `OVERLAPS`
8. `NOT`
9. `AND`
10. `OR`

**Khác biệt:** PostgreSQL `::` chặt hơn hầu hết. `NOT` T-SQL dễ đọc sai: `WHERE NOT a = b AND c` = `(NOT (a = b)) AND c` hay khác — **luôn ngoặc**.

```sql
WHERE NOT (a = b) AND c = 1;

-- PostgreSQL: 2^3+1
SELECT 2 ^ 3 + 1;             -- (2^3)+1 = 9  — ^ cao hơn +
```

SQL Server không có `^` lũy thừa (dùng `POWER()`). `^` T-SQL = XOR bit, mức bitwise.

`~` regex PG là so sánh pattern, mức so sánh — không unary bit. `~1` integer = đảo bit. Cùng glyph, khác arity/type.

`IGNORE NULLS` không có precedence toán tử: gắn sau `LAG(x)` trước `OVER`. Viết `WHERE x IGNORE NULLS` = lỗi parse.

---

## 3. Số học

```sql
SELECT 7 / 2;                 -- cả hai: 3 (integer)
SELECT 7.0 / 2;               -- numeric
SELECT 7 / 2.0;               -- numeric hoặc float tùy engine/literal
```

| | SQL Server | PostgreSQL |
|---|---|---|
| Chia nguyên | Cắt về 0 | Cắt về 0 |
| `%` modulo | Có (số) | Có (số) |
| Lũy thừa | `POWER(a,b)` | `^` hoặc `POWER` |
| XOR bit | `^` | `#` |
| `PRODUCT()` | Aggregate **2025** | thủ công `exp(sum(ln()))` |

### 3.1 Chia nguyên & modulo

```sql
SELECT 7 / 2;                 -- 3
SELECT -7 / 2;                -- -3 (cắt về 0, không floor kiểu Python)
SELECT 7 % 2;                 -- 1
SELECT -7 % 2;                -- -1 (dấu theo dividend, cả hai)
```

Chia 0: **lỗi** integer (`Divide by zero` / `division by zero`). Float PG: `Inf` / `NaN`. Đừng dựa vào short-circuit `denom <> 0 AND num/denom` — §5.

```sql
-- Trước: không an toàn
WHERE denom <> 0 AND num / denom > 1

-- Sau
WHERE CASE WHEN denom <> 0 THEN num / denom END > 1
```

### 3.2 Lũy thừa vs XOR

```sql
-- PostgreSQL
SELECT 2 ^ 10;                -- 1024.0 (float8 thường)
SELECT 1 # 3;                 -- XOR bit = 2
SELECT 2 ^ 3 ^ 2;             -- kết hợp trái: (2^3)^2 = 64

-- SQL Server
SELECT POWER(2, 10);          -- 1024
SELECT 1 ^ 3;                 -- XOR = 2
-- SELECT 2 ^ 10;             -- XOR, không phải 1024
```

**Ghi chú:** Port `^` từ PG sang T-SQL đổi thành XOR im lặng nếu không review. `POWER` trả float → tiền tệ dùng `numeric` nhân lặp / `POWER` rồi `CAST`.

### 3.3 `PRODUCT()`

```sql
-- SQL Server 2025
SELECT PRODUCT(rate) FROM dbo.DailyRates WHERE Day >= @from;

-- PostgreSQL (chỉ dương)
SELECT exp(sum(ln(rate))) FROM daily_rates WHERE day >= :from AND rate > 0;
```

Overflow / `numeric` theo kiểu đầu vào. Zero/âm phá `ln()`. NULL: aggregate bỏ NULL (như `SUM`) — hàng toàn NULL → `NULL`. Không phải toán tử infix `*`; không `IGNORE NULLS` (đó là window offset).

---

## 4. So sánh

```sql
=   <>   !=   <   >   <=   >=
```

`!=` alias `<>` trên cả hai; `<>` là dạng chuẩn. So sánh chuỗi: collation — [dialects.md](dialects.md). `NULL = NULL` → `UNKNOWN`, không phải `TRUE`.

### 4.1 `BETWEEN`, `IN`

```sql
WHERE x BETWEEN 1 AND 10;                -- 1 ≤ x ≤ 10 (đóng hai đầu)
WHERE x BETWEEN 10 AND 1;                -- luôn sai nếu 10 > 1 (không tự đảo)
WHERE x IN (1, 2, 3);
WHERE x IN (SELECT id FROM t);           -- NULL trong list/subquery → UNKNOWN cho hàng đó
```

```sql
-- Bẫy IN + NULL
WHERE status IN ('open', NULL);          -- ≡ status = 'open' OR status = NULL
                                         -- nhánh NULL không bao giờ TRUE → không lấy status IS NULL
```

`NOT IN (SELECT …)` khi subquery có **một** NULL → cả predicate `UNKNOWN` → **zero row**. PG **19**: `NOT IN` **không NULL** có thể rewrite ANTI JOIN — vẫn giữ bẫy NULL. Optimizer đổi plan, không cứu `NOT IN (SELECT nullable)`.

```sql
-- An toàn
WHERE NOT EXISTS (SELECT 1 FROM t WHERE t.id = x.id)
-- hoặc WHERE x NOT IN (SELECT id FROM t WHERE id IS NOT NULL)
```

### 4.2 `ALL` / `ANY` / `SOME`

```sql
WHERE x > ALL (SELECT v FROM t);         -- > MAX nếu không NULL; NULL trong t → UNKNOWN
WHERE x = ANY (SELECT v FROM t);         -- ≡ IN
WHERE x = SOME (SELECT v FROM t);        -- ≡ ANY
```

Empty subquery: `> ALL ()` = TRUE; `> ANY ()` = FALSE (chuẩn). Test khi port.

`GROUP BY ALL` (PG 19) **không** phải `> ALL`. Đó là cú pháp group — [keywords.md](keywords.md), [select.md](select.md).

---

## 5. Logic & three-valued

```sql
AND   OR   NOT
```

| A | B | A AND B | A OR B |
|---|---|---|---|
| T | U | U | T |
| F | U | F | U |
| U | U | U | U |

`TRUE AND UNKNOWN` → `UNKNOWN` → `WHERE` loại hàng.

Short-circuit **không được chuẩn hóa**. Optimizer reorder. Hàm user / chia 0 / raise trong predicate có thể chạy dù nhánh “trước” false.

```sql
-- T-SQL: AND/OR không bảo đảm không gọi UDF bên phải
WHERE @flag = 1 AND dbo.Expensive(@id) = 1
```

`CASE` / `IIF` (SQL Server) có thứ tự đánh giá chặt hơn predicate `AND` — vẫn không dùng UDF có side effect trong `SELECT` list nếu có thể.

PostgreSQL `WHERE is_active` (boolean). T-SQL `WHERE IsActive` **không** đủ — `bit` không phải predicate: `WHERE IsActive = 1`.

PG 19: nhiều `LEFT JOIN` có thể rewrite ANTI; hash join NULL key — plan, không đổi `AND`/`OR` three-valued.

---

## 6. Chuỗi

```sql
-- Nối
SELECT 'a' + 'b';                        -- SQL Server (NULL + x = NULL khi CONCAT_NULL_YIELDS_NULL ON)
SELECT 'a' || 'b';                       -- PostgreSQL; SQL Server **2022+**
SELECT CONCAT('a', NULL, 'b');           -- 'ab' trên cả hai (bỏ/treate NULL như '')
```

| Biểu thức | SQL Server (ANSI ON) | PostgreSQL |
|---|---|---|
| `'a' + NULL` | `NULL` | lỗi kiểu (không `+` text) |
| `'a' \|\| NULL` | `NULL` (2022+) | `NULL` |
| `CONCAT('a', NULL)` | `'a'` | `'a'` |

`+` T-SQL: nếu một bên số, **cộng số** (convert chuỗi → số). `'1'+2` = 3; `'a'+2` lỗi.

```sql
-- SQL Server: ép nối
SELECT CONCAT(@n, N' items');
SELECT CONVERT(varchar(20), @n) + ' items';
```

Pattern `LIKE` không phải nối. Regex: §7. `||` jsonb PG = merge document, khác nối text — overload type — §10, §15.

---

## 7. `LIKE` / `SIMILAR` / regex

`LIKE` wildcard: `%` (nhiều ký tự), `_` (một). **Không** phải regex.

```sql
WHERE name LIKE 'A%';
WHERE name LIKE 'A\%' ESCAPE '\';        -- % literal
```

| | SQL Server `LIKE` | PostgreSQL `LIKE` |
|---|---|---|
| `[A-Z]` | Character class | `[` **ký tự thường** |
| Case | Theo collation (CI/CS) | Case-sensitive (dùng `ILIKE` hoặc collation) |
| Escape | `ESCAPE` | `ESCAPE` |

```sql
-- SQL Server CI: 'abc' LIKE '[A-Z]%'     — có thể TRUE (class + CI)
-- PostgreSQL:     'abc' LIKE '[A-Z]%'     — TRUE chỉ nếu name bắt đầu bằng '['

-- PostgreSQL
WHERE name ILIKE 'a%';                   -- case-insensitive
WHERE name SIMILAR TO '%(foo|bar)%';     -- SQL regex (không phải POSIX)
WHERE name ~ '^[A-Z]';                   -- POSIX
WHERE name ~* 'hello';                   -- POSIX, case-insensitive
WHERE name !~ ' ';
WHERE name !~* 'x';

-- SQL Server 2025: regex native (GA) — HÀM, không infix ~
WHERE REGEXP_LIKE(name, N'^[A-Z]');
SELECT REGEXP_REPLACE(Phone, N'[^0-9]', N'');
SELECT REGEXP_SUBSTR(s, pattern);
SELECT REGEXP_INSTR(s, pattern);
SELECT REGEXP_COUNT(s, pattern);
-- REGEXP_MATCHES, REGEXP_SPLIT_TO_TABLE — table-valued
```

**`REGEXP_LIKE` vs `~`**

| | SQL Server 2025 | PostgreSQL |
|---|---|---|
| Predicate | `REGEXP_LIKE(expr, pattern [, flags])` | `expr ~ pattern` / `~*` |
| Replace | `REGEXP_REPLACE` | `regexp_replace` |
| Extract | `REGEXP_SUBSTR` / `REGEXP_INSTR` | `substring(… from pattern)` / `regexp_match` |
| Split / set | `REGEXP_SPLIT_TO_TABLE`, `REGEXP_MATCHES` | `regexp_split_to_table`, `regexp_matches` |
| Infix `~` | **Không** (bit `~` unary) | POSIX |
| `SIMILAR TO` | Không | SQL regex |
| `LIKE` class `[ ]` | Có | Không |

Flags: SS `N'i'` trên `REGEXP_INSTR` (ví dụ Learn) — đối chiếu docs từng hàm, không copy flag POSIX `~*` thành tham số thứ 3 mù. Collation / Unicode tiếng Việt: **test**, regex không tự CI như `LIKE` CI.

Literal pattern: PG 19 `'…'` không escape `\` — pattern `'\\d+'` vs `E'\\d+'` — [literals.md](literals.md).

**Ghi chú:** `LIKE '%x'` không sargable; `LIKE 'x%'` thường dùng index. POSIX `~` không dùng index trừ trigram (`pg_trgm`) / regex index riêng. Regex SS **không** biến `LIKE '%x'` thành seek. Index: computed persisted / full-text — không bịa regex index native.

`SIMILAR TO` dùng `%` `_` như `LIKE` **cộng** `\|()[]` SQL regex — không phải POSIX `~`. Port `~` → `SIMILAR TO` sai.

---

## 8. NULL-safe

```sql
IS NULL / IS NOT NULL
IS [NOT] DISTINCT FROM                   -- SQL Server 2022+; PostgreSQL lõi
```

```sql
WHERE a IS NOT DISTINCT FROM b;          -- TRUE khi cả hai NULL hoặc bằng nhau
WHERE a IS DISTINCT FROM b;              -- TRUE khi khác, kể cả một bên NULL
```

Hai session — lost compare:

```text
T1: SELECT * FROM t WHERE k = @k;        -- @k NULL → 0 hàng
T2: đúng: WHERE k IS NOT DISTINCT FROM @k
```

`IS TRUE` / `IS FALSE` / `IS UNKNOWN`: PostgreSQL đầy đủ (`TRUE IS NOT FALSE`). SQL Server không có trên `bit` — `= 1` / `= 0` / `IS NULL`.

**PG 19 optimizer:** fold `IS [NOT] DISTINCT FROM NULL` → `IS [NOT] NULL` (cùng nghĩa, plan gọn). Fold `COALESCE` / `ROW IS NULL` liên quan. **Không** đổi kết quả; không có toán tử mới. Compat SQL Server **không** fold này (170 đổi CE khác).

```sql
-- Hai cách cùng nghĩa (PG 19 plan có thể giống)
WHERE k IS DISTINCT FROM NULL;           -- fold → IS NOT NULL
WHERE k IS NOT NULL;
```

`COALESCE(a,b)` / `IFNULL` (T-SQL) / `NULLIF(a,b)`: hàm, không phải toán tử infix. `COALESCE` dừng ở đối số đầu không NULL (được định nghĩa hơn `AND`).

`IGNORE NULLS` trên `LAG` **không** phải `IS DISTINCT FROM`. Window bỏ NULL khi offset — [window-functions.md](window-functions.md). Viết `a IGNORE NULLS b` = không parse.

---

## 9. Tập hợp

```sql
UNION              -- distinct
UNION ALL
INTERSECT [ALL]
EXCEPT [ALL]       -- SQL Server: EXCEPT; không MINUS (Oracle)
```

| | SQL Server | PostgreSQL |
|---|---|---|
| `UNION [ALL]` | Có | Có |
| `INTERSECT` | Distinct | Distinct |
| `INTERSECT ALL` / `EXCEPT ALL` | **Không** | Có |
| `MINUS` | Không | Không |

Thứ tự cột + kiểu tương thích (precedence convert). `ORDER BY` chỉ sau tập hợp ngoài; dùng vị trí số hoặc alias cột đầu tiên.

```sql
SELECT id FROM a
UNION ALL
SELECT id FROM b
ORDER BY 1;

-- Số cột lệch → lỗi. NULL neo kiểu:
SELECT CAST(NULL AS int)
UNION ALL
SELECT id FROM t;
```

`UNION` (distinct) sort/hash — đắt. Mặc định viết `UNION ALL` khi biết không trùng.

---

## 10. JSON

```sql
-- SQL Server: hàm, không infix ->
SELECT JSON_VALUE(doc, '$.name');        -- scalar (lax: miss → NULL)
SELECT JSON_QUERY(doc, '$.items');       -- object/array
SELECT JSON_MODIFY(doc, '$.name', N'Ada');
-- kiểu json 2025: vẫn hàm; JSON INDEX PREVIEW — json.md / typesystem.md

-- PostgreSQL jsonb
SELECT doc -> 'name';                    -- jsonb
SELECT doc ->> 'name';                   -- text
SELECT doc -> 'items' -> 0;
SELECT doc #> '{user,name}';
SELECT doc #>> '{user,name}';
SELECT doc @> '{"ok": true}'::jsonb;
SELECT doc ? 'name';                     -- key tồn tại
SELECT doc ?| ARRAY['a','b'];
SELECT doc || '{"x":1}'::jsonb;          -- merge (jsonb)
```

### `JSON_CONTAINS` (SQL Server 2025, **PREVIEW** on-prem)

Hàm containment, không operator `@>`. Tối ưu khi có **JSON INDEX** (cũng **PREVIEW**, clustered PK). Wildcard path ANSI — [json.md](json.md).

```sql
-- PREVIEW on-prem — đối chiếu Learn cú pháp path
SELECT *
FROM dbo.Doc
WHERE JSON_CONTAINS(Payload, N'open', '$.status');  -- hình thức: docs 2025
```

Không copy `WHERE doc @> '{"status":"open"}'` sang T-SQL. Không copy `JSON_CONTAINS` sang PG — dùng `@>` / `jsonb_path_ops` GIN.

`JSON_QUERY … WITH ARRAY WRAPPER` (**PREVIEW**): scalar miss vs array — hàm, không infix.

**Ghi chú:** `JSON_VALUE` ra object → `NULL` (dùng `JSON_QUERY`). PG `->` giữ jsonb (có thể index); `->>` text. `@>` containment sargable với GIN. SQL Server không có `@>`. `?` PG “key exists” ≠ T-SQL ternary (T-SQL không `? :`).

`json_array()` 0 hàng → `[]` PG **19** — constructor, không toán tử — [literals.md](literals.md), [typesystem.md](typesystem.md).

---

## 11. Array / range / overlap

```sql
-- PostgreSQL
SELECT ARRAY[1,2] || 3;                  -- {1,2,3}
SELECT ARRAY[1,2] && ARRAY[2,3];         -- overlap
SELECT int4range(1,5) && int4range(4,8);
SELECT int4range(1,5) @> 3;
SELECT int4range(1,5) <@ int4range(0,10);
SELECT '[2026-01-01,2026-07-01)'::daterange;
```

SQL Server: overlap temporal = period system-versioned / `FOR SYSTEM_TIME` — không có `&&` native (trừ spatial `STIntersects`, hoặc so sánh hai mốc). PG 19 `FOR PORTION OF` cắt range — [dml.md](dml.md). **Không** toán tử mới; clause DML.

Array index **1-based**. `tags[0]` → `NULL` không lỗi.

`&&` PostGIS (bounding box) **cùng tên** khác type — §15. `&&` array ≠ `&&` range ≠ `&&` geometry.

---

## 12. Bit

```sql
-- SQL Server
SELECT 1 & 3, 1 | 2, 1 ^ 3, ~1;
-- Không có << >> trong T-SQL; dịch bit bằng nhân/chia lũy thừa 2 hoặc hàm riêng

-- PostgreSQL
SELECT 1 & 3, 1 | 2, 1 # 3, ~1;          -- XOR là #
SELECT 1 << 3, 8 >> 2;
```

`~` trên integer có dấu: đảo bit toàn width → số âm. Mask tường minh (`& 255`).

SQL Server `bit` kiểu cột 0/1 không phải bit-string; toán `&` trên `int`. PG `bit(n)` / `varbit` có operator riêng khác `int`.

`~` regex vs `~` bit: `WHERE name ~ '^a'` vs `SELECT ~1`. Parser chọn theo operand.

---

## 13. Vector & fuzzy

### Vector

```sql
-- SQL Server 2025 GA: hàm, không infix <->
SELECT VECTOR_DISTANCE('cosine', a.Embedding, b.Embedding);
-- PREVIEW: VECTOR_SEARCH (ANN) — cần PREVIEW_FEATURES — typesystem.md

-- PostgreSQL pgvector (extension)
SELECT embedding <-> :q FROM doc ORDER BY 1 LIMIT 10;     -- L2 thường
SELECT embedding <=> :q;                                  -- cosine (docs pgvector)
```

**Không** port `<=>` sang T-SQL. **Không** port `VECTOR_DISTANCE` sang PG core. Half-precision vs float32: cùng hàm/operator, khác storage — [typesystem.md](typesystem.md).

### Fuzzy — SQL Server **PREVIEW** (`PREVIEW_FEATURES`)

```sql
-- PREVIEW — không production mặc định
SELECT EDIT_DISTANCE(N'kitten', N'sitting');
SELECT EDIT_DISTANCE_SIMILARITY(a, b);
SELECT JARO_WINKLER_DISTANCE(a, b);
SELECT JARO_WINKLER_SIMILARITY(a, b);
```

PostgreSQL: extension `fuzzystrmatch` (`levenshtein`, …) — **không** cùng tên hàm SS. Không GA core 19.

**Ghi chú:** Fuzzy không sargable btree thông thường. Bật `PREVIEW_FEATURES` kéo vector index/CES trên cùng DB — [dialects.md](dialects.md). Regex GA (`REGEXP_*`) ≠ fuzzy PREVIEW.

`IGNORE NULLS` không áp dụng `EDIT_DISTANCE`. `FILTER (WHERE …)` trên aggregate PG ≠ fuzzy.

---

## 14. Gán & compound (T-SQL)

```sql
-- SQL Server
SET @i = @i + 1;
SET @i += 1;                             -- compound: += -= *= /= %= &= ^= |=
UPDATE dbo.T SET Qty += 1 WHERE Id = 1;

-- PostgreSQL: không biến @; trong PL/pgSQL
-- i := i + 1;
UPDATE t SET qty = qty + 1 WHERE id = 1;
```

`=` trong `WHERE` là so sánh; trong `SET` / `UPDATE SET` là gán. `UPDATE t SET a = b = 1` T-SQL **không** gán chuỗi kiểu C.

PostgreSQL `UPDATE … SET (a,b) = (1,2)` row assignment. SQL Server: từng cột hoặc `UPDATE … FROM`.

`^=` T-SQL = XOR gán, không lũy thừa.

---

## 15. Overload (PostgreSQL)

Mọi toán tử là hàng `pg_operator`. Schema + `search_path` + kiểu quyết định. Extension (`pgvector`, PostGIS) thêm `<=>`, `&&` khác *cùng tên* khác operand type.

```sql
SELECT oprname, oprleft::regtype, oprright::regtype
FROM pg_operator
WHERE oprname = '&&';
```

```sql
CREATE OPERATOR === (
    LEFTARG = int, RIGHTARG = int,
    PROCEDURE = int4eq
);
```

`operator is not unique`: ép `::jsonb` / `::int4range`. SQL Server không `CREATE OPERATOR`.

`search_path` độc hại đổi `&&` — [dialects.md](dialects.md), [routines.md](routines.md).

---

## 16. Hai session — ví dụ làm việc

### 16.1 `NOT IN` NULL vs ANTI JOIN 19

```text
T1: WHERE id NOT IN (SELECT k FROM t);     -- t.k có một NULL → 0 hàng (cả hai engine)
T2: PG 19, t.k NOT NULL: plan ANTI JOIN    -- nhanh hơn, cùng nghĩa
-- Review: “19 rewrite NOT IN” không được khi cột nullable.
```

### 16.2 `IS DISTINCT FROM NULL` fold

```text
T1 (PG 18): WHERE x IS DISTINCT FROM NULL; -- plan có IS DISTINCT
T2 (PG 19): cùng SQL                       -- fold IS NOT NULL, index IS NOT NULL dùng được như trước
-- Kết quả hàng: giống. SQL Server 2022+: không fold này; IS DISTINCT FROM vẫn đúng.
```

### 16.3 Regex `LIKE` class port

```text
T1 (SS CI): WHERE sku LIKE '[A-Z]%'        -- chữ hoa/thường theo CI
T2 (PG):    WHERE sku LIKE '[A-Z]%'        -- chỉ sku bắt đầu '['
            WHERE sku ~ '^[A-Z]'           -- POSIX
            -- SS 2025: WHERE REGEXP_LIKE(sku, N'^[A-Z]')
```

### 16.4 Fuzzy PREVIEW vs regex GA

```text
T1: REGEXP_LIKE(email, N'@contoso\.com$')  -- GA 2025, prod OK nếu test
T2: EDIT_DISTANCE(name, @q) < 2            -- PREVIEW; CU có thể đổi; đừng khóa search prod
```

### 16.5 `JSON_CONTAINS` vs `@>`

```text
T1 (SS PREVIEW): JSON_CONTAINS(doc, …) + JSON INDEX
T2 (PG):         doc @> '{"status":"open"}'::jsonb  + GIN
-- Port path $.a đệ quy SS ≠ jsonb containment. Đo, đừng dịch máy.
```

### 16.6 Chia 0 + `AND`

```text
T1: WHERE denom <> 0 AND num/denom > 1     -- vẫn có thể chia 0 (reorder)
T2: CASE WHEN denom <> 0 THEN num/denom END > 1
```

---

## 17. Best practices & checklist

- Ngoặc `NOT` / bitwise / `^`.
- Chia: một toán hạng `numeric` khi cần thập phân; bảo vệ /0 bằng `CASE`.
- `NOT IN` subquery: cấm NULL hoặc dùng `NOT EXISTS` — đừng tin rewrite ANTI 19 khi nullable.
- Nối chuỗi: `CONCAT` / `||`; không `'1'+@n` T-SQL.
- NULL-safe: `IS DISTINCT FROM`, không `=` cho khóa nullable. PG 19 fold `… NULL` = `IS NULL`.
- Regex: `REGEXP_LIKE` (2025 GA) vs `~` / `ILIKE`; `LIKE` class `[ ]` chỉ T-SQL. Pattern `\` nhớ E-string 19.
- Fuzzy / `JSON_CONTAINS` / `VECTOR_SEARCH`: **PREVIEW**.
- `IGNORE NULLS`: window file, không `WHERE`.
- Tập hợp: `UNION ALL` mặc định; `EXCEPT ALL` không port sang SQL Server.
- JSON: PG `->` / `@>` vs SS hàm; đừng giả `@>` trên T-SQL.
- Port `^`: PG power ≠ T-SQL XOR.
- Vector: hàm SS vs operator pgvector.

---

## 18. Bẫy khi review

- `WHERE col = NULL`.
- `NOT IN (SELECT nullable)` — kể cả sau PG 19 ANTI rewrite docs.
- `denom <> 0 AND num/denom` như C.
- `'a' + 1` T-SQL vs PG.
- `LIKE '[0-9]%'` copy sang PG.
- `2 ^ 8` “bit shift” trên PG (thành 256.0).
- `INTERSECT ALL` trong SQL “chuẩn” trên SQL Server.
- Short-circuit UDF / `RAISERROR` trong `AND`.
- `JSON_VALUE` lấy object.
- `JSON_CONTAINS` / `@>` copy chéo dialect.
- `tags[0]` mong phần tử đầu PG.
- `SET ANSI` `CONCAT_NULL_YIELDS_NULL OFF` làm `+` nuốt NULL — [dialects.md](dialects.md).
- Fuzzy distance trên prod khi chưa chấp nhận **PREVIEW**.
- `name ~ pattern` trên T-SQL (thành bit `~` / lỗi).
- `IGNORE NULLS` trong `WHERE` / trên `SUM` SS.
- `GROUP BY ALL` hiểu là `> ALL`.
- Mix `<=>` pgvector với `VECTOR_DISTANCE`.
- `IS DISTINCT FROM NULL` “toán tử mới 19” (chỉ fold).

---

## 19. Version gates

| Mục | SQL Server | PostgreSQL |
|---|---|---|
| `\|\|` nối chuỗi | **2022+** | lõi |
| `IS [NOT] DISTINCT FROM` | **2022+** | lõi |
| Fold `IS DISTINCT FROM NULL` | — | **19** (optimizer) |
| `NOT IN` → ANTI JOIN (không NULL) | tùy CE | **19** |
| `REGEXP_LIKE` / `REGEXP_*` | **2025 GA** | `~` `SIMILAR TO` lâu |
| Fuzzy `EDIT_DISTANCE` / `JARO_WINKLER_*` | **2025 PREVIEW** | `fuzzystrmatch` ext |
| `JSON_CONTAINS` / JSON INDEX | **2025 PREVIEW** on-prem | `@>` GIN lâu |
| `VECTOR_DISTANCE` | **2025 GA** | pgvector `<->` / `<=>` |
| `VECTOR_SEARCH` | **2025 PREVIEW** | pgvector ANN index |
| `PRODUCT()` | **2025** | — |
| `+=` compound | lõi T-SQL | PL `:=` / `qty = qty + 1` |
| `<<` `>>` integer | — | lõi |
| `^` lũy thừa | `POWER()` | lõi |
| `#` XOR | `^` | lõi |
| `INTERSECT ALL` | — | lõi |
| `IGNORE NULLS` window | — (không toán tử) | **19** — [window-functions.md](window-functions.md) |

Join / `APPLY`: [joins.md](joins.md). Window `FILTER`: [window-functions.md](window-functions.md). Keyword `LIKE`/`AND`: [keywords.md](keywords.md). Kiến trúc overload/index AM: [internal.md](internal.md).

---

## Phụ lục A. `REGEXP_LIKE` — hàm vs infix, flags

SQL Server 2025 **GA**: họ `REGEXP_*` là hàm (một số TVF). PostgreSQL: infix `~` / `~*` + hàm `regexp_*`.

```sql
-- SQL Server: đối chiếu Learn từng tham số (start, occurrence, return_option, flags)
SELECT REGEXP_INSTR(Body, N'error', 1, 1, 0, N'i');
SELECT REGEXP_REPLACE(Phone, N'[^0-9]', N'');
SELECT * FROM REGEXP_MATCHES(Body, N'(\w+)=(\w+)');
SELECT * FROM REGEXP_SPLIT_TO_TABLE(Csv, N',');

-- PostgreSQL
SELECT regexp_match(body, '(\w+)=(\w+)');
SELECT * FROM regexp_matches(body, '(\w+)=(\w+)', 'g');
SELECT regexp_replace(phone, '[^0-9]', '', 'g');
SELECT * FROM regexp_split_to_table(csv, ',');
```

**Ghi chú:** Flag `'g'` PG (global) không copy mù thành tham số SS. `REGEXP_LIKE` trả predicate (dùng `WHERE`); `~` trả boolean. `REGEXP_LIKE` không thay `LIKE` sargable prefix. Tiếng Việt / Unicode: test collation — regex không tự CI như `LIKE` trên DB CI.

Hai session — CI `LIKE` vs regex:

```text
T1 (SS CI): WHERE name LIKE 'a%'           -- 'Ada' khớp
T2 (SS):    WHERE REGEXP_LIKE(name, N'^a') -- có thể CS tùy flag — thêm N'i' nếu cần
T2 (PG):    WHERE name ~ '^a'              -- CS; ~* hoặc ILIKE cho CI
```

Không có `REGEXP_LIKE` trên PG. Không có `~` regex trên T-SQL (`~` = bit NOT).

---

## Phụ lục B. `JSON_CONTAINS` vs `@>` vs `JSON_VALUE`

Cùng ý “document có mảnh này?” — ba surface.

```sql
-- PostgreSQL (GA lâu)
WHERE doc @> '{"status":"open"}'::jsonb
WHERE doc ->> 'status' = 'open'              -- text, dễ lệch kiểu số/bool

-- SQL Server
WHERE JSON_VALUE(Payload, '$.status') = N'open'          -- GA, lax miss → NULL
-- PREVIEW on-prem:
-- WHERE JSON_CONTAINS(Payload, …)                        -- containment + JSON INDEX
```

| | Sargable khi |
|---|---|
| `@>` jsonb | GIN `jsonb_path_ops` / `jsonb_ops` |
| `JSON_VALUE` = hằng | computed persisted / JSON INDEX **PREVIEW** |
| `JSON_CONTAINS` | JSON INDEX **PREVIEW**; clustered PK |

Path `$.a` đệ quy SS (gồm `$.a.b`) **không** cùng `@>` (object chứa key/value ở mức containment). Port máy = sai hàng.

`JSON_QUERY` + `WITH ARRAY WRAPPER` (**PREVIEW**): miss scalar vs bọc array — hàm, không toán tử. Chi tiết: [json.md](json.md).

---

## Phụ lục C. `LIKE ESCAPE` hai session

```sql
-- Cả hai
WHERE sku LIKE 'A\%B' ESCAPE '\';
```

```text
T1 (SS): LIKE 'A[B]%'                     -- class: A rồi B
T2 (PG): LIKE 'A[B]%'                     -- A rồi '[' rồi 'B' rồi ']' …
T1 (SS CI): LIKE '[A-Z]%'                 -- chữ cái
T2 (PG):     LIKE '[A-Z]%'                -- không class
            LIKE 'A\%' ESCAPE '\'         -- A + %
```

PG 19: `ESCAPE '\'` — trong `'…'` một `\`. Dump 18 `off`: `'ESCAPE '''` / `E'\\' ` lệch. Dollar `ESCAPE $$\$$$` đọc khó — giữ `'\'` + conforming on.

`ESCAPE` không biến `%` đầu thành sargable. `LIKE '\%x'` vẫn scan.

---

## Phụ lục D. Vector distance — hàm vs operator

| Việc | SQL Server 2025 | pgvector |
|---|---|---|
| L2 / cosine / … | `VECTOR_DISTANCE('cosine', a, b)` **GA** | `<->` L2, `<=>` cosine, `<#>` (docs extension) |
| ANN k-NN | `VECTOR_SEARCH` **PREVIEW** | `ORDER BY embedding <-> q LIMIT k` + IVFFlat/HNSW |
| Chuẩn hóa | `VECTOR_NORMALIZE` | hàm extension / tự chia norm |
| Chiều | `VECTORPROPERTY(…, 'Dimensions')` | typmod `vector(n)` |

```sql
-- Đừng
-- WHERE embedding <=> @q < 0.2          -- T-SQL: <=> không có
-- WHERE VECTOR_DISTANCE('cosine', …)    -- PG core: không có
```

Metric `'cosine'` là **chuỗi literal** tới hàm SS — sai chính tả = lỗi runtime, không phải toán tử. Half vs float32: § typesystem phụ lục C.

Fuzzy **PREVIEW** (`EDIT_DISTANCE`) là chuỗi ký tự, không vector. Không `IGNORE NULLS` trên `VECTOR_DISTANCE`.

---

## Phụ lục E. `FILTER` / `IGNORE NULLS` — không phải toán tử đây

```sql
-- PostgreSQL aggregate FILTER (lâu)
SELECT SUM(total) FILTER (WHERE status = 'paid') FROM orders;

-- PostgreSQL 19 window
SELECT LAG(v) IGNORE NULLS OVER (ORDER BY ts)

-- SQL Server: SUM(CASE WHEN status = N'paid' THEN total END)
-- IGNORE NULLS: không giả trên SUM / PRODUCT / VECTOR_DISTANCE
```

Review trap: thấy `IGNORE NULLS` trong PR toán tử/`WHERE` → chuyển [window-functions.md](window-functions.md). `PRODUCT` 2025 bỏ NULL như `SUM`, không cần (và không có) `IGNORE NULLS` aggregate SS.
