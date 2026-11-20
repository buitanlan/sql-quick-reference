# Toán tử (Operators)

> **Baseline:** SQL Server **2025** · PostgreSQL **19** (GA 19/11/2026).<br>
> Precedence không giống C# / C. Khi nghi ngờ — **dùng ngoặc**.

Toán tử SQL gắn với *kiểu* và *three-valued logic*, không với method overload kiểu C#. `=` vừa so sánh vừa (T-SQL) gán trong `SET`; `+` vừa cộng vừa nối chuỗi trên SQL Server; PostgreSQL `^` là lũy thừa, `#` mới là XOR. Optimizer **được** đổi thứ tự `AND`/`OR` — không có short-circuit chuẩn. File này là ngữ nghĩa để review, không phải bảng ghi nhớ một dòng.

Kiểu toán hạng: [typesystem.md](typesystem.md). NULL / `UNKNOWN`: [dialects.md](dialects.md). JSON sâu: [json.md](json.md).

`IGNORE NULLS` / `RESPECT NULLS` là **clause window**, không toán tử infix — [window-functions.md](window-functions.md), [keywords.md](keywords.md). Không nhét vào `WHERE`.

---

## Mục lục

- [1. Tổng quan & triết lý](#1-tổng-quan--triết-lý)
- [2. Precedence](#2-precedence)
- [3. Số học](#3-số-học)
  - [3.1 Chia nguyên & modulo](#31-chia-nguyên--modulo)
  - [3.2 Lũy thừa vs XOR](#32-lũy-thừa-vs-xor)
  - [3.3 `PRODUCT()`](#33-product)
- [4. So sánh](#4-so-sánh)
  - [4.1 `BETWEEN`, `IN`](#41-between-in)
  - [4.2 `ALL` / `ANY` / `SOME`](#42-all--any--some)
- [5. Logic & three-valued](#5-logic--three-valued)
- [6. Chuỗi](#6-chuỗi)
- [7. `LIKE` / `SIMILAR` / regex](#7-like--similar--regex)
- [8. NULL-safe](#8-null-safe)
- [9. Tập hợp](#9-tập-hợp)
- [10. JSON](#10-json)
  - [`JSON_CONTAINS` (SQL Server 2025, **GA**)](#json_contains-sql-server-2025-ga)
- [11. Array / range / overlap](#11-array--range--overlap)
- [12. Bit](#12-bit)
- [13. Vector & fuzzy](#13-vector--fuzzy)
  - [Vector](#vector)
  - [Fuzzy — SQL Server (GA từ CU11)](#fuzzy--sql-server-ga-từ-cu11)
- [14. Gán & compound (T-SQL)](#14-gán--compound-t-sql)
- [15. Overload (PostgreSQL)](#15-overload-postgresql)
- [16. Hai session — ví dụ làm việc](#16-hai-session--ví-dụ-làm-việc)
  - [16.1 `NOT IN` NULL vs ANTI JOIN 19](#161-not-in-null-vs-anti-join-19)
  - [16.2 `IS DISTINCT FROM NULL` fold](#162-is-distinct-from-null-fold)
  - [16.3 Regex `LIKE` class port](#163-regex-like-class-port)
  - [16.4 Fuzzy (GA từ CU11) vs regex GA](#164-fuzzy-ga-từ-cu11-vs-regex-ga)
  - [16.5 `JSON_CONTAINS` vs `@>`](#165-json_contains-vs-)
  - [16.6 Chia 0 + `AND`](#166-chia-0--and)
- [17. Best practices & checklist](#17-best-practices--checklist)
- [18. Bẫy khi review](#18-bẫy-khi-review)
- [19. Version gates](#19-version-gates)
- [Phụ lục A. `REGEXP_LIKE` — hàm vs infix, flags](#phụ-lục-a-regexp_like--hàm-vs-infix-flags)
- [Phụ lục B. `JSON_CONTAINS` vs `@>` vs `JSON_VALUE`](#phụ-lục-b-json_contains-vs--vs-json_value)
- [Phụ lục C. `LIKE ESCAPE` hai session](#phụ-lục-c-like-escape-hai-session)
- [Phụ lục D. Vector distance — hàm vs operator](#phụ-lục-d-vector-distance--hàm-vs-operator)
- [Phụ lục E. `FILTER` / `IGNORE NULLS` — không phải toán tử đây](#phụ-lục-e-filter--ignore-nulls--không-phải-toán-tử-đây)
- [Nguồn chính thức](#nguồn-chính-thức)

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

**Ghi chú:** Regex SQL Server 2025 là **hàm** `REGEXP_LIKE` (GA), không infix `~`. Fuzzy `EDIT_DISTANCE` / `JARO_WINKLER_*` **GA từ CU11** (12/11/2026). `JSON_CONTAINS` là hàm **GA**. PG 19 fold `IS DISTINCT FROM NULL` là optimizer, không toán tử mới.

---

## 2. Precedence

**Hình dung.** SQL không phải C#: `NOT` và `AND` dễ đọc nhầm, PostgreSQL `^` là **lũy thừa** (rất chặt) trong khi SQL Server `^` là **XOR**. `2 ^ 3 + 1` trên PG = 9, không phải bit. Nghi ngờ thì ngoặc — rẻ hơn debug.

Rút gọn (cao → thấp) — **tách theo engine** vì nhiều mức khác nhau hẳn:

| Mức | SQL Server | PostgreSQL |
|---|---|---|
| 1 | `~` (bitwise NOT) | `.` (truy cập thành phần) |
| 2 | `*` `/` `%` | `::` (PG cast), `[]` (subscript) |
| 3 | Unary `+` `-`, binary `+` `-`, **bitwise `&` `^` `\|`** *(cùng mức, trái → phải!)* | `^` (lũy thừa — **cao hơn cả unary `-`**) |
| 4 | So sánh: `=` `>` `<` `>=` `<=` `<>` `!=` `!>` `!<` | Unary `+` `-` |
| 5 | `NOT` | `*` `/` `%` |
| 6 | `AND` | `+` `-` (binary) |
| 7 | `ALL` `ANY` `BETWEEN` `IN` `LIKE` `OR` `SOME` | Toán tử khác (gồm bitwise `&` `\|` `#` `~` `<<` `>>`, `\|\|`, `@>`, regex `~`, ...) |
| 8 | `=` `+=` `-=` ... (gán) | `BETWEEN` `IN` `LIKE` `ILIKE` `SIMILAR TO` → `<` `>` `=` `<=` `>=` `<>` → `IS` (`IS NULL`, `IS DISTINCT FROM`) → `NOT` → `AND` → `OR` |

**Khác biệt chí mạng:**

- **PG `^` cao hơn `* / %` và unary `-`:** `-2 ^ 2` trên PG là `-(2 ^ 2) = -4` (không phải `4`); `2 ^ 3 + 1 = 9`.
- **SQL Server bitwise `& ^ |` cùng mức với `+ -` (trái → phải):** `1 | 2 + 1` trên SQL Server = `(1 | 2) + 1 = 4`, còn trên PG = `1 | (2 + 1) = 3`!
- **`NOT` dễ đọc sai:** `WHERE NOT a = b AND c` — **luôn dùng ngoặc**: `WHERE NOT (a = b) AND c = 1;`.

```sql
WHERE NOT (a = b) AND c = 1;

-- PostgreSQL
SELECT -2 ^ 2;                -- -4 (vì ^ chặt hơn unary -; muốn 4 viết (-2) ^ 2)
SELECT 2 ^ 3 + 1;             -- (2^3)+1 = 9
SELECT 1 | 2 + 1;             -- 3: + chặt hơn | trên PG

-- SQL Server
SELECT 1 | 2 + 1;             -- 4: | và + cùng mức, tính trái → phải: (1 | 2) + 1
```

SQL Server không có `^` lũy thừa (dùng `POWER()`). `^` T-SQL = XOR bit, mức bitwise.

`~` regex PG là so sánh pattern, mức so sánh — không unary bit. `~1` integer = đảo bit. Cùng glyph, khác arity/type.

`IGNORE NULLS` không có precedence toán tử: gắn sau `LAG(x)` trước `OVER`. Viết `WHERE x IGNORE NULLS` = lỗi parse.

---

## 3. Số học

```sql
SELECT 7 / 2;                 -- cả hai: 3 (integer)
SELECT 7.0 / 2;               -- numeric
SELECT 7 / 2.0;               -- numeric ở cả hai engine (2.0 là numeric, không phải float)
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

Chia 0: **lỗi** integer (`Divide by zero` / `division by zero`). PostgreSQL cũng báo lỗi chia 0 đối với float; có literal Infinity/NaN không có nghĩa phép chia 0 sẽ tạo chúng. Đừng dựa vào short-circuit `denom <> 0 AND num/denom` — §5.

```sql
-- Trước: không an toàn
WHERE denom <> 0 AND num / denom > 1

-- Sau
WHERE num / NULLIF(denom, 0) > 1
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

**Ghi chú:** Port `^` từ PG sang T-SQL đổi thành XOR im lặng nếu không review. Trên SQL Server, `POWER(a, b)` trả về **cùng kiểu với tham số thứ nhất** (`POWER(2, 10)` trả `int` — rất dễ tràn `int`, vd `POWER(2, 31)` lỗi overflow; chỉ trả `float` khi tham số 1 là `float`). Trên PostgreSQL, `^` / `power(int, int)` trả `double precision`, còn `power(numeric, numeric)` trả `numeric`. Tiền tệ nên ép `numeric` trước khi tính.

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

**Row-value comparison (PostgreSQL):** PG hỗ trợ so sánh tuple theo thứ tự từ điển trái → phải: `WHERE (created_at, id) > ($1, $2)` (rất gọn cho keyset pagination — [select.md](select.md), dùng được composite B-tree index). SQL Server **không** hỗ trợ so sánh tuple trực tiếp — phải viết tường minh `WHERE created_at > @t OR (created_at = @t AND id > @id)`.

### 4.1 `BETWEEN`, `IN`

```sql
WHERE x BETWEEN 1 AND 10;                -- 1 ≤ x ≤ 10 (đóng hai đầu)
WHERE x BETWEEN 10 AND 1;                -- luôn sai nếu 10 > 1 (không tự đảo)
WHERE x IN (1, 2, 3);
WHERE x IN (SELECT id FROM t);           -- NULL trong list/subquery chỉ thành UNKNOWN khi x không khớp phần tử non-NULL nào
```

```sql
-- Bẫy IN + NULL
WHERE status IN ('open', NULL);          -- ≡ status = 'open' OR status = NULL
                                         -- nếu status = 'open' → vẫn TRUE; không khớp mới thành UNKNOWN (không lấy status IS NULL)
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

**Tập rỗng (empty subquery):** `x > ALL (empty)` luôn trả **`TRUE`** và `x > ANY (empty)` luôn trả **`FALSE`** theo chuẩn SQL — **kể cả khi `x` là `NULL`** (`NULL > ALL (empty)` = `TRUE`, `NULL > ANY (empty)` = `FALSE`, vì không có phần tử nào để phản chứng / thỏa mãn). Test kỹ khi subquery có thể rỗng.


---

## 5. Logic & three-valued

**Hình dung: `AND` không phải `if`.**

Trong C, `if (a && expensive())` thường **không gọi** `expensive` khi `a` sai. SQL **không hứa** vậy. Optimizer được đảo `AND`/`OR`. `WHERE denom <> 0 AND num / denom > 1` vẫn có thể chia 0.

Muốn thứ tự chắc: `CASE WHEN denom <> 0 THEN num / denom END > 1`.

`NOT a = b AND c` đọc được hai cách. Luôn ngoặc: `WHERE NOT (a = b) AND c = 1`.

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

`CASE` / `IIF` (SQL Server) có thứ tự đánh giá chặt hơn `AND`, nhưng **vẫn không đảm bảo short-circuit tuyệt đối** trên cả hai engine: biểu thức **aggregate** trong nhánh `THEN` được tính trước (`CASE WHEN 1 = 0 THEN SUM(1 / 0) END` vẫn lỗi chia 0) và **constant folding / expression simplification** lúc biên dịch có thể evaluate biểu thức hằng trong nhánh không được chọn (`CASE WHEN 1 = 0 THEN 1 / 0 END` dễ lỗi). Tránh dựa vào side effect UDF trong `SELECT`/`CASE`.

PostgreSQL `WHERE is_active` (boolean). T-SQL `WHERE IsActive` **không** đủ — `bit` không phải predicate: `WHERE IsActive = 1`.

PG 19: nhiều `LEFT JOIN` có thể rewrite ANTI; hash join NULL key — plan, không đổi `AND`/`OR` three-valued.

---

## 6. Chuỗi

```sql
-- Nối
SELECT 'a' + 'b';                        -- SQL Server (NULL + x = NULL khi CONCAT_NULL_YIELDS_NULL ON)
SELECT 'a' || 'b';                       -- PostgreSQL; SQL Server **2025**
SELECT CONCAT('a', NULL, 'b');           -- 'ab' trên cả hai (bỏ/treat NULL như '')
```

| Biểu thức | SQL Server (ANSI ON) | PostgreSQL |
|---|---|---|
| `'a' + NULL` | `NULL` | lỗi kiểu (không `+` text) |
| `'a' \|\| NULL` | `NULL` (2025) | `NULL` |
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
| Escape mặc định | **Không có** (`\` là ký tự thường; chỉ escape khi ghi `ESCAPE '...'`) | **`\` là ký tự escape mặc định** (kể cả khi `standard_conforming_strings = on`; muốn tắt ghi `ESCAPE ''`) |

```sql
-- SQL Server CI: 'abc' LIKE '[A-Z]%'     — có thể TRUE (class + CI)
-- PostgreSQL:     'abc' LIKE '[A-Z]%'     — TRUE chỉ nếu name bắt đầu bằng '['

-- Bẫy backslash trong LIKE (đường dẫn Windows / chuỗi có '\'):
-- SQL Server: 'C:\temp' LIKE 'C:\t%'      → TRUE (không có escape mặc định)
-- PostgreSQL: 'C:\temp' LIKE 'C:\t%'      → FALSE! ('\t' bị LIKE escape thành chữ 't' thường → tìm 'C:t%')
--             'C:\temp' LIKE 'C:\\t%'     → TRUE (hoặc: 'C:\temp' LIKE 'C:\t%' ESCAPE '')

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
-- REGEXP_MATCHES, REGEXP_SPLIT_TO_TABLE — table-valued (dùng với CROSS APPLY khi áp lên cột)
```

**`REGEXP_LIKE` vs `~`**

| | SQL Server 2025 | PostgreSQL |
|---|---|---|
| Predicate | `REGEXP_LIKE(expr, pattern [, flags])` | `expr ~ pattern` / `~*`; `regexp_like(expr, pattern [, flags])` (**15+**) |
| Replace | `REGEXP_REPLACE` | `regexp_replace` |
| Extract / count | `REGEXP_SUBSTR` / `REGEXP_INSTR` / `REGEXP_COUNT` | `substring(… from pattern)` / `regexp_match`; `regexp_substr` / `regexp_instr` / `regexp_count` (**15+**) |
| Split / set | `REGEXP_SPLIT_TO_TABLE`, `REGEXP_MATCHES` (TVF + `CROSS APPLY`) | `regexp_split_to_table`, `regexp_matches` |
| Infix `~` | **Không** (bit `~` unary) | POSIX |
| `SIMILAR TO` | Không | SQL regex |
| `LIKE` class `[ ]` | Có | Không |

Flags: SS `N'i'` trên `REGEXP_INSTR` (ví dụ Learn) — đối chiếu docs từng hàm, không copy flag POSIX `~*` thành tham số thứ 3 mù. Collation / Unicode tiếng Việt: **test**, regex không tự CI như `LIKE` CI.

Literal pattern: PG 19 `'…'` không escape `\` — pattern `'\\d+'` vs `E'\\d+'` — [literals.md](literals.md).

**Ghi chú:** `LIKE '%x'` không sargable; `LIKE 'x%'` thường dùng index. POSIX `~` không dùng index trừ trigram (`pg_trgm`) / regex index riêng. Regex SS **không** biến `LIKE '%x'` thành seek. Index: computed persisted / full-text — không bịa regex index native.

`SIMILAR TO` dùng `%` `_` như `LIKE` **cộng** `|()[]` SQL regex — không phải POSIX `~`. Port `~` → `SIMILAR TO` sai.

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

`COALESCE(a, b, ...)` / `ISNULL(a, b)` (T-SQL) / `NULLIF(a, b)`: hàm, không phải toán tử infix.

**SQL Server `ISNULL` vs `COALESCE` — ba khác biệt thực chiến:**

| Trục | `ISNULL(a, b)` (T-SQL) | `COALESCE(a, b, ...)` (ANSI) |
|---|---|---|
| Kiểu trả về | Ép về kiểu của **tham số đầu `a`** (`ISNULL(CAST(NULL AS varchar(3)), 'abcdef')` bị cắt thành `'abc'`) | Chọn kiểu theo **data type precedence** cao nhất (trả `'abcdef'`) |
| Nullability metadata | `NOT NULL` nếu fallback khác `NULL` (dùng được làm PK/computed `NOT NULL`) | Luôn đánh dấu **nullable** trong metadata `SELECT INTO` / view / computed column |
| Đánh giá biểu thức | Đánh giá `a` **1 lần** | Rewrite thành `CASE WHEN a IS NOT NULL THEN a ELSE b END` → **đánh giá `a` 2 lần**! Với subquery hoặc hàm non-deterministic (`NEWID()`, `NEXT VALUE FOR`), có thể chạy 2 lần và thậm chí vẫn trả `NULL` |

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
-- kiểu json 2025: vẫn hàm; JSON INDEX GA — json.md / typesystem.md

-- PostgreSQL jsonb
SELECT doc -> 'name';                    -- jsonb
SELECT doc ->> 'name';                   -- text
SELECT doc -> 'items' -> 0;
SELECT doc #> '{user,name}';
SELECT doc #>> '{user,name}';
SELECT doc @> '{"ok": true}'::jsonb;     -- containment
SELECT doc ? 'name';                     -- key tồn tại
SELECT doc ?| ARRAY['a','b'];            -- tồn tại ÍT NHẤT 1 key
SELECT doc ?& ARRAY['a','b'];            -- tồn tại TẤT CẢ các key
SELECT doc || '{"x":1}'::jsonb;          -- merge (shallow, top-level)
SELECT doc - 'temp';                     -- xóa key (hoặc xóa phần tử mảng theo index int)
SELECT doc #- '{user,temp}';             -- xóa theo path lồng nhau
SELECT doc @? '$.items[*] ? (@.qty > 5)';-- JSONPath có ít nhất 1 phần tử khớp (PG 12+)
SELECT doc @@ '$.ok == true';            -- JSONPath predicate trả boolean (PG 12+)
```

### `JSON_CONTAINS` (SQL Server 2025, **GA**)

Hàm containment, không operator `@>`. Tối ưu khi có **JSON INDEX** (cũng **GA**, clustered PK). Wildcard path ANSI — [json.md](json.md).

```sql
-- SQL Server 2025 (GA) — đối chiếu Learn cú pháp path (trả int 1/0/NULL)
SELECT *
FROM dbo.Doc
WHERE JSON_CONTAINS(Payload, N'open', '$.status') = 1;
```

Không copy `WHERE doc @> '{"status":"open"}'` sang T-SQL. Không copy `JSON_CONTAINS` sang PG — dùng `@>` / `jsonb_path_ops` GIN.

`JSON_QUERY … WITH ARRAY WRAPPER` (**GA**): scalar miss vs array — hàm, không infix.

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

SQL Server: overlap temporal = period system-versioned / `FOR SYSTEM_TIME` — không có `&&` native (trừ spatial `STIntersects`, hoặc so sánh hai mốc). Range `&&` kiểm overlap.

Array index **1-based**. `tags[0]` → `NULL` không lỗi.

`&&` PostGIS (bounding box) **cùng tên** khác type — §15. `&&` array ≠ `&&` range ≠ `&&` geometry.

---

## 12. Bit

```sql
-- SQL Server
SELECT 1 & 3, 1 | 2, 1 ^ 3, ~1;
-- Không có toán tử infix << >> trong T-SQL; từ SQL Server 2022+ có hàm bit built-in:
SELECT LEFT_SHIFT(1, 3), RIGHT_SHIFT(8, 2), BIT_COUNT(7), GET_BIT(5, 2), SET_BIT(5, 1, 1);

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

### Fuzzy — SQL Server (GA từ CU11)

```sql
-- GA từ CU11 (12/11/2026). RTM–CU10 cần PREVIEW_FEATURES.
SELECT EDIT_DISTANCE(N'kitten', N'sitting');
SELECT EDIT_DISTANCE_SIMILARITY(a, b);
SELECT JARO_WINKLER_DISTANCE(a, b);
SELECT JARO_WINKLER_SIMILARITY(a, b);
```

PostgreSQL: extension `fuzzystrmatch` (`levenshtein`, …), dùng tên hàm khác SQL Server; cần cài extension trong database.

**Ghi chú:** Fuzzy không sargable btree thông thường. Từ CU11 không cần `PREVIEW_FEATURES`. Flag này vẫn cần cho vector index, `VECTOR_SEARCH`, half-precision và CES trên cùng DB — [dialects.md](dialects.md). Regex GA (`REGEXP_*`) là họ khác fuzzy.

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

### 16.4 Fuzzy (GA từ CU11) vs regex GA

```text
T1: REGEXP_LIKE(email, N'@contoso\.com$')  -- GA 2025, prod OK nếu test
T2: EDIT_DISTANCE(name, @q) < 2            -- GA từ CU11; trước đó cần PREVIEW_FEATURES
```

### 16.5 `JSON_CONTAINS` vs `@>`

```text
T1 (SS GA): JSON_CONTAINS(doc, …) + JSON INDEX
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
- `JSON_CONTAINS` GA. Fuzzy **GA từ CU11**. `VECTOR_SEARCH` vẫn PREVIEW trên on-prem.
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
- `LIKE '[0-9]%'` copy sang PG; hoặc `LIKE 'C:\t%'` trên PG quên rằng `\` là ký tự escape mặc định.
- `2 ^ 8` “bit shift” trên PG (thành `256.0`); hoặc `-2 ^ 2` trên PG tưởng bằng `4` (thực tế `-4`); hoặc `1 | 2 + 1` trên SQL Server tưởng bằng `3` (thực tế `4`).
- `INTERSECT ALL` trong SQL “chuẩn” trên SQL Server.
- Short-circuit UDF / `RAISERROR` trong `AND`, hoặc đặt aggregate / biểu thức hằng chia 0 trong `CASE` mong short-circuit.
- `COALESCE(subquery, 0)` trên SQL Server đánh giá subquery 2 lần (hoặc `ISNULL` cắt ngắn chuỗi theo độ dài tham số đầu).
- `JSON_VALUE` lấy object.
- `JSON_CONTAINS` / `@>` copy chéo dialect.
- `tags[0]` mong phần tử đầu PG.
- `SET ANSI` `CONCAT_NULL_YIELDS_NULL OFF` làm `+` nuốt NULL — [dialects.md](dialects.md).
- Dùng hàm fuzzy (`EDIT_DISTANCE`, `JARO_WINKLER_*`) trên SQL Server 2025 RTM–CU10 mà quên rằng bản trước CU11 cần `PREVIEW_FEATURES` (từ CU11 đã GA).
- `name ~ pattern` trên T-SQL (thành bit `~` / lỗi).
- `IGNORE NULLS` trong `WHERE` / trên `SUM` SS.
- Mix `<=>` pgvector với `VECTOR_DISTANCE`.
- `IS DISTINCT FROM NULL` “toán tử mới 19” (chỉ fold).

---

## 19. Version gates

| Mục | SQL Server | PostgreSQL |
|---|---|---|
| `\|\|` nối chuỗi | **2025** | lõi |
| `IS [NOT] DISTINCT FROM` | **2022+** | lõi |
| Fold `IS DISTINCT FROM NULL` | — | **19** (optimizer) |
| `NOT IN` → ANTI JOIN (không NULL) | tùy CE | **19** |
| `REGEXP_LIKE` / `REGEXP_*` | **2025 GA** | `~` / `SIMILAR TO` lâu; `regexp_like`/`count`/`instr`/`substr` **15+** |
| Fuzzy `EDIT_DISTANCE` / `JARO_WINKLER_*` | **GA từ CU11** | `fuzzystrmatch` ext |
| `JSON_CONTAINS` / JSON INDEX | **2025 GA** | `@>` GIN lâu; `@?` / `@@` **12+** |
| `VECTOR_DISTANCE` | **2025 GA** | pgvector `<->` / `<=>` |
| `VECTOR_SEARCH` | **2025 PREVIEW** | pgvector ANN index |
| `PRODUCT()` | **2025** | — |
| `+=` compound | lõi T-SQL | PL `:=` / `qty = qty + 1` |
| `<<` `>>` dịch bit | **2022+** hàm `LEFT_SHIFT`/`RIGHT_SHIFT`/`BIT_COUNT`/`GET_BIT`/`SET_BIT` | lõi (`<<` `>>`) |
| `^` lũy thừa | `POWER()` | lõi |
| `#` XOR | `^` | lõi |
| `INTERSECT ALL` | — | lõi |
| `IGNORE NULLS` window | **2022+** (không toán tử) | **19** — [window-functions.md](window-functions.md) |

Join / `APPLY`: [joins.md](joins.md). Window `FILTER`: [window-functions.md](window-functions.md). Keyword `LIKE`/`AND`: [keywords.md](keywords.md). Kiến trúc overload/index AM: [internal.md](internal.md).

---

## Phụ lục A. `REGEXP_LIKE` — hàm vs infix, flags

SQL Server 2025 **GA**: họ `REGEXP_*` là hàm (một số TVF). PostgreSQL: infix `~` / `~*` + hàm `regexp_*`.

```sql
-- SQL Server: đối chiếu Learn từng tham số (start, occurrence, return_option, flags)
SELECT REGEXP_INSTR(Body, N'error', 1, 1, 0, N'i') FROM dbo.Doc;
SELECT REGEXP_REPLACE(Phone, N'[^0-9]', N'') FROM dbo.Doc;
SELECT d.Id, m.* FROM dbo.Doc AS d CROSS APPLY REGEXP_MATCHES(d.Body, N'(\w+)=(\w+)') AS m;
SELECT d.Id, s.* FROM dbo.Doc AS d CROSS APPLY REGEXP_SPLIT_TO_TABLE(d.Csv, N',') AS s;

-- PostgreSQL (15+ có thêm regexp_like, regexp_count, regexp_instr, regexp_substr)
SELECT regexp_like(body, 'error', 'i'), regexp_count(body, 'error', 1, 'i') FROM doc;
SELECT regexp_match(body, '(\w+)=(\w+)') FROM doc;
SELECT d.id, m FROM doc AS d CROSS JOIN LATERAL regexp_matches(d.body, '(\w+)=(\w+)', 'g') AS m;
SELECT regexp_replace(phone, '[^0-9]', '', 'g') FROM doc;
SELECT d.id, s FROM doc AS d CROSS JOIN LATERAL regexp_split_to_table(d.csv, ',') AS s;
```

**Ghi chú:** Flag `'g'` PG (global) không copy mù thành tham số SS. `REGEXP_LIKE` trả predicate (dùng `WHERE`); `~` trả boolean. `REGEXP_LIKE` không thay `LIKE` sargable prefix. Tiếng Việt / Unicode: test collation — regex không tự CI như `LIKE` trên DB CI.

Hai session — CI `LIKE` vs regex:

```text
T1 (SS CI): WHERE name LIKE 'a%'           -- 'Ada' khớp
T2 (SS):    WHERE REGEXP_LIKE(name, N'^a') -- có thể CS tùy flag — thêm N'i' nếu cần
T2 (PG):    WHERE name ~ '^a'              -- CS; ~* hoặc regexp_like(name, '^a', 'i') cho CI
```

PostgreSQL **15+ đã có** bộ hàm chuẩn `regexp_like`, `regexp_count`, `regexp_instr`, `regexp_substr` (bên cạnh `~`/`~*`). Ngược lại, T-SQL không có toán tử infix `~` regex (`~` là bitwise NOT).

---

## Phụ lục B. `JSON_CONTAINS` vs `@>` vs `JSON_VALUE`

Cùng ý “document có mảnh này?” — ba surface.

```sql
-- PostgreSQL (GA lâu)
WHERE doc @> '{"status":"open"}'::jsonb
WHERE doc ->> 'status' = 'open'              -- text, dễ lệch kiểu số/bool

-- SQL Server 2025 (GA)
WHERE JSON_VALUE(Payload, '$.status') = N'open'          -- GA, lax miss → NULL
WHERE JSON_CONTAINS(Payload, N'open', '$.status') = 1    -- GA, containment + JSON INDEX
```

| | Sargable khi |
|---|---|
| `@>` jsonb | GIN `jsonb_path_ops` / `jsonb_ops` |
| `JSON_VALUE` = hằng | computed (deterministic) / JSON INDEX **GA** |
| `JSON_CONTAINS` | JSON INDEX **GA**; clustered PK |

Path `$.a` đệ quy SS (gồm `$.a.b`) **không** cùng `@>` (object chứa key/value ở mức containment). Port máy = sai hàng.

`JSON_QUERY` + `WITH ARRAY WRAPPER` (**GA**): miss scalar vs bọc array — hàm, không toán tử. Chi tiết: [json.md](json.md).

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
T1 (SS):     LIKE 'C:\t%'                 -- khớp 'C:\temp' (SS không có escape mặc định)
T2 (PG):     LIKE 'C:\t%'                 -- KHÔNG khớp 'C:\temp' (PG mặc định '\' là escape → dùng 'C:\\t%' hoặc ESCAPE '')
             LIKE 'A\%' ESCAPE '\'        -- A + %
```

PG 19: `ESCAPE '\'` — trong `'…'` một `\`; lưu ý trên PG `\` vốn đã là ký tự escape **mặc định** của `LIKE` (dùng `ESCAPE ''` để tắt). Dump 18 `off`: `'ESCAPE '''` / `E'\\'` lệch. Dollar `ESCAPE $$\$$` đọc khó — giữ `'\'` + conforming on.

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

Metric `'cosine'` là **chuỗi literal** tới hàm SS — sai chính tả = lỗi runtime, không phải toán tử. Half vs float32: [typesystem.md — Phụ lục C](typesystem.md#phụ-lục-c-half-precision-vector--dung-lượng).

Fuzzy (**GA từ CU11**, `EDIT_DISTANCE`) là so sánh chuỗi ký tự, không phải vector. Không `IGNORE NULLS` trên `VECTOR_DISTANCE`.

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

---

## Nguồn chính thức

Đối chiếu ngày **21/11/2026**. PostgreSQL **19** GA **19/11/2026**. SQL Server 2025 **CU11** (12/11/2026): fuzzy GA; vector index, `VECTOR_SEARCH`, half-precision và CES vẫn PREVIEW. Xem [baseline và quy ước ví dụ](README.md#trạng-thái-phiên-bản-và-cách-kiểm-chứng).

- [PostgreSQL operators](https://www.postgresql.org/docs/19/sql-syntax-lexical.html#SQL-PRECEDENCE)
- [T-SQL string concatenation pipes (2025)](https://learn.microsoft.com/en-us/sql/t-sql/language-elements/string-concatenation-pipes-transact-sql?view=sql-server-ver17)
- [JSON_CONTAINS](https://learn.microsoft.com/en-us/sql/t-sql/functions/json-contains-transact-sql?view=sql-server-ver17)
