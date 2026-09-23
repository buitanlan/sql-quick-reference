# Hàm built-in

> **Baseline:** SQL Server **2025** (17.x) · PostgreSQL **19**.  
> File này: **built-in**. Hàm / procedure / trigger do người viết: [routines.md](routines.md). Window: [window-functions.md](window-functions.md). JSON: [json.md](json.md). Kiểu `vector` / `date`: [typesystem.md](typesystem.md).

Hàm SQL không phải thư viện C: mỗi lời gọi gắn với *kiểu*, *collation*, *determinism*, và *khi nào engine đánh giá*. Cùng tên `SUBSTRING` / `now()` trên hai dialect **không** cùng hợp đồng. Optimizer được nhân bản hay hoãn gọi miễn kết quả logic giữ — trừ hàm volatile. File này là ngữ nghĩa để review, không phải bảng “mọi hàm có trên trái đất”.

---

## Mục lục

- [1. Tổng quan \& triết lý](#1-tổng-quan--triết-lý)
- [2. Chuỗi](#2-chuỗi)
  - [2.1 Độ dài, cắt, trim](#21-độ-dài-cắt-trim)
  - [2.2 Nối, tách, gộp](#22-nối-tách-gộp)
  - [2.3 `UNISTR`](#23-unistr)
  - [2.4 Base64](#24-base64)
- [3. Regex](#3-regex)
  - [3.1 SQL Server 2025 `REGEXP_*`](#31-sql-server-2025-regexp_)
  - [3.2 PostgreSQL `regexp_*` / `~`](#32-postgresql-regexp_--)
  - [3.3 Port flag \& RE2](#33-port-flag--re2)
- [4. Fuzzy (PREVIEW)](#4-fuzzy-preview)
- [5. Ngày giờ](#5-ngày-giờ)
  - [5.1 “Hiện tại” \& `CURRENT_DATE`](#51-hiện-tại--current_date)
  - [5.2 Cộng trừ \& trunc — `DATEADD` bigint](#52-cộng-trừ--trunc--dateadd-bigint)
  - [5.3 `AT TIME ZONE`](#53-at-time-zone)
- [6. Aggregate](#6-aggregate)
  - [6.1 `COUNT` / `SUM` / `AVG`](#61-count--sum--avg)
  - [6.2 `PRODUCT()`](#62-product)
  - [6.3 `FILTER`](#63-filter)
- [7. Điều kiện](#7-điều-kiện)
- [8. `CAST` / `TRY_CAST`](#8-cast--try_cast)
- [9. Vector \& AI](#9-vector--ai)
  - [9.1 `VECTOR_DISTANCE` / `NORM` / `NORMALIZE` / `PROPERTY`](#91-vector_distance--norm--normalize--property)
  - [9.2 `AI_GENERATE_*`](#92-ai_generate_)
  - [9.3 pgvector](#93-pgvector)
- [10. System](#10-system)
- [11. Determinism: `now()` vs `clock_timestamp()`](#11-determinism-now-vs-clock_timestamp)
- [12. Worked examples](#12-worked-examples)
- [13. Best practices \& checklist](#13-best-practices--checklist)
- [14. Bẫy khi review](#14-bẫy-khi-review)
- [15. Version gates](#15-version-gates)
- [Phụ lục A. Sargable \& collation](#phụ-lục-a-sargable--collation)

---

## 1. Tổng quan & triết lý

Năm lớp, đừng trộn:

| Lớp | Đầu vào | Đầu ra | Ví dụ |
|---|---|---|---|
| Scalar | một hàng | một giá trị | `LOWER`, `DATEADD`, `COALESCE` |
| Aggregate | nhóm hàng | một giá trị / nhóm | `SUM`, `PRODUCT`, `string_agg` |
| Window | partition + frame | một giá trị / hàng | `LAG`, `SUM() OVER` |
| SRF / TVF | tham số | bảng | `generate_series`, `REGEXP_SPLIT_TO_TABLE` |
| Ordered-set | nhóm + thứ tự | một giá trị | PG `percentile_cont`; SS `PERCENTILE_CONT` là *window* |

Hàm trong `WHERE`/`JOIN` trên cột thường **phá sargable** — [select.md](select.md). Collation quyết định `LOWER`/`LIKE`/`~`. NULL: hầu hết scalar trả `NULL` nếu đối số `NULL`; aggregate **bỏ** `NULL` (trừ `COUNT(*)`).

PostgreSQL gắn `IMMUTABLE` / `STABLE` / `VOLATILE` lên catalog; SQL Server có danh sách deterministic cho indexed view / persisted computed. Sai nhãn = index sai hoặc kết quả đổi giữa hai lần đọc — §11, [routines.md](routines.md).

Gọi HTTP từ hàm (`AI_GENERATE_EMBEDDINGS`, `sp_invoke_external_rest_endpoint`) không phải scalar thuần: timeout, secret, không sargable, không nhét OLTP nóng — [routines.md](routines.md).

---

## 2. Chuỗi

| Việc | SQL Server | PostgreSQL |
|---|---|---|
| Số ký tự | `LEN` (bỏ trailing space) | `char_length` / `length` |
| Số byte | `DATALENGTH` | `octet_length` |
| Cắt | `LEFT` `RIGHT` `SUBSTRING` | `left` `right` `substring` |
| Hoa/thường | `UPPER` `LOWER` | `upper` `lower` |
| Trim | `TRIM` `LTRIM` `RTRIM` | `trim` `btrim` `ltrim` `rtrim` |
| Nối | `CONCAT` `CONCAT_WS` `+` `\|\|` (2022+) | `concat` `concat_ws` `\|\|` |
| Tách | `STRING_SPLIT` | `string_to_array` / `unnest` / `regexp_split_to_table` |
| Gộp | `STRING_AGG` | `string_agg` |
| Pad | `REPLICATE` / `SPACE` | `lpad` `rpad` `repeat` |
| Unicode escape | `UNISTR` (**2025**) | `U&'…'` / `chr` / `U&'\xxxx'` |
| Base64 | `BASE64_ENCODE` / `BASE64_DECODE` (**2025**) | `encode` / `decode` (`bytea`) |
| Base64 URL | `BASE64_ENCODE(x, 1)` (**2025**) | `encode(x, 'base64url')` (**19**) |
| Fuzzy | `EDIT_DISTANCE`… (**PREVIEW**) | `levenshtein` (`fuzzystrmatch`) |

### 2.1 Độ dài, cắt, trim

```sql
-- SQL Server
SELECT LEN(N'abc ');                          -- 3  (bỏ space cuối)
SELECT DATALENGTH(N'abc ');                   -- 8  (nvarchar: 2 byte/ký tự + space)
SELECT SUBSTRING(N'abcdef', 3);               -- N'cdef' — length optional (2025, ANSI)
SELECT SUBSTRING(N'abcdef', 3, 2);            -- N'cd'
SELECT TRIM(BOTH 'x' FROM N'xxabxx');         -- N'ab'

-- PostgreSQL
SELECT length('abc ');                        -- 4
SELECT octet_length('abc ');                  -- 4 (UTF-8, ASCII)
SELECT substring('abcdef' FROM 3);            -- 'cdef'
SELECT substring('abcdef' FROM 3 FOR 2);      -- 'cd'
SELECT btrim('xxabxx', 'x');                  -- 'ab'
```

`LEN` T-SQL **không** đếm trailing space; đo storage / binary dùng `DATALENGTH`. `CHARINDEX` / `PATINDEX` (SS) ≠ `strpos` / `position` (PG). Vị trí **1-based** cả hai.

**Ghi chú:** `SUBSTRING(s, 3)` thiếu `length` là **2025**. Bản cũ bắt buộc ba đối số. Port từ PG `substring(s FROM 3)` sang SS 2019 sẽ lỗi cú pháp.

### 2.2 Nối, tách, gộp

```sql
SELECT CONCAT('a', NULL, 'b');                -- 'ab'  (cả hai: NULL → rỗng)
SELECT CONCAT_WS(', ', first_name, last_name);

-- SQL Server: + phụ thuộc CONCAT_NULL_YIELDS_NULL (mặc định ON → NULL)
SELECT N'a' + NULL;                           -- NULL
SELECT STRING_SPLIT(N'a,b,c', N',', 1);       -- enable_ordinal = 1 (2022+): cột ordinal
SELECT STRING_AGG(name, N',') WITHIN GROUP (ORDER BY name);

-- PostgreSQL
SELECT 'a' || NULL;                           -- NULL
SELECT unnest(string_to_array('a,b,c', ','));
SELECT string_agg(name, ',' ORDER BY name);
```

`STRING_SPLIT` không bảo đảm thứ tự nếu **không** `enable_ordinal`. `string_to_array` giữ thứ tự. Gộp có `ORDER BY` tường minh — thiếu thì thứ tự **không xác định**.

Delimiter regex: SS `REGEXP_SPLIT_TO_TABLE` (§3); PG `regexp_split_to_table`. `STRING_SPLIT` chỉ delimiter *một* ký tự (2022+ cho phép nhiều ký tự trên một số bản — đối chiếu Learn theo CU, đừng giả delimiter regex).

**Ghi chú:** `CONCAT` nuốt NULL; `||` / `+` (ANSI NULL) **không**. Review “sao mất đoạn giữa” thường là NULL cột, không phải bug `CONCAT`.

### 2.3 `UNISTR`

SQL Server **2025**: chuyển escape Unicode trong chuỗi thành ký tự. Escape mặc định `\`; tùy chọn ký tự escape thứ hai.

```sql
-- SQL Server 2025
SELECT UNISTR(N'Hello! \D83D\DE00');          -- UTF-16 code units
SELECT UNISTR(N'Hello! \+01F603');            -- codepoint Unicode (\+xxxxxx)
SELECT UNISTR(N'ABC#00C0#0181#0187', N'#');   -- escape tùy chọn '#'
SELECT N'Hello! ' + NCHAR(0xd83d) + NCHAR(0xde00);  -- từng code unit — dài hơn
```

`char`/`varchar` đầu vào cần collation **UTF-8** (code page 65001) hoặc Unicode-only. Collation legacy (code page ≠ 0 và ≠ 65001) **không** tương thích `UNISTR`. `NCHAR` chỉ một code unit; `UNISTR` nhận nhiều escape trong một literal.

PostgreSQL **không** có `UNISTR`. Literal Unicode:

```sql
SELECT U&'Hello! \+01F603';                   -- escape U& standard
SELECT U&'d\00E9j\00E0' UESCAPE '!';          -- UESCAPE đổi dấu (mặc định \)
SELECT chr(128515);                           -- codepoint → text
```

Đừng bịa `unistr()` trên PG 19. `E'...'` + `\u` phụ thuộc `standard_conforming_strings` (19 **luôn on** — backslash trong literal thường **không** escape trừ `E''`).

**Ghi chú:** `\xxxx` = UTF-16; `\+xxxxxx` = codepoint. Surrogate pair (`\D83D\DE00`) ≠ một `\+01F600` cùng glyph — test fixture, đừng mix mù.

### 2.4 Base64

```sql
-- SQL Server 2025
SELECT BASE64_ENCODE(CAST('hello' AS varbinary(max)));           -- alphabet RFC 4648 T1, có padding
SELECT BASE64_ENCODE(0xCAFECAFE, 1);                             -- url_safe ≠ 0: alphabet T2, **không** padding
SELECT BASE64_DECODE('aGVsbG8=');                                -- → varbinary
```

`BASE64_ENCODE(expr [, url_safe])`: `url_safe` mặc định `0`. Khác 0 → Base64URL (`-`/`_` thay `+`/`/`), không `=`. Output `varchar(8000)` nếu input `varbinary(n)` với `n ≤ 6000`, ngược lại `varchar(max)`. `NULL` → `NULL`. Không chèn newline. Chuỗi URL-safe **không** tương thích decoder Base64 của XML/JSON SQL Server — đừng nhét vào `FOR XML` rồi decode như T1.

```sql
-- PostgreSQL: encode/decode trên bytea
SELECT encode('\xdeadbeef'::bytea, 'hex');
SELECT encode('\xdeadbeef'::bytea, 'base64');
SELECT encode('\xdeadbeef'::bytea, 'base64url');   -- **19**: RFC 4648 §5, không padding
SELECT encode('\xdeadbeef'::bytea, 'base32hex');   -- **19**: giữ thứ tự, khác base32
SELECT decode('3q2-7w', 'base64url');              -- \xdeadbeef
-- decode('3q2-7w', 'base64') → ERROR: invalid symbol "-"
```

Trước 19, PG chỉ `hex` / `escape` / `base64`. `base64url` **không** tồn tại trên 18 — đừng port `encode(..., 'base64url')` xuống bản cũ. `decode` format phải khớp encode; `-`/`_` chỉ hợp `base64url`.

**Ghi chú:** `url_safe` SS và `'base64url'` PG cùng họ RFC 4648 T2 — vẫn test padding/`=` vì SS `url_safe` **bỏ** padding; pipeline JWT/URL nhạy padding.

---

## 3. Regex

`LIKE` **không** phải regex. T-SQL `LIKE` có character class `[0-9]`; PostgreSQL `LIKE` không — dùng `~` / `SIMILAR TO` / `regexp_like`. Chi tiết operator: [operators.md](operators.md).

### 3.1 SQL Server 2025 `REGEXP_*`

Native, thư viện **RE2**. Flag chỉ `{c,i,s,m}` — **không** có `g`. `string_expression` LOB tối đa **2 MB**. `pattern` tối đa **8000 byte**. Flag mặc định `c` (case-sensitive); chuỗi rỗng = `c`; flag mâu thuẫn lấy **ký tự cuối** (`ic` → case-sensitive). Flag lạ → lỗi `Only {c,i,s,m} flags are valid`.

| Hàm | Vai trò | Compat |
|---|---|---|
| `REGEXP_LIKE` | boolean khớp | **170** |
| `REGEXP_REPLACE` | thay | mọi level trên engine 2025 |
| `REGEXP_SUBSTR` | cắt nhóm/lần khớp | mọi level |
| `REGEXP_INSTR` | vị trí bắt đầu/kết thúc | mọi level |
| `REGEXP_COUNT` | đếm lần khớp | mọi level |
| `REGEXP_MATCHES` | TVF mọi lần + capture | **170** (hoặc `ALLOW_BUILTIN_TVF_IN_ALL_COMPAT_LEVELS`) |
| `REGEXP_SPLIT_TO_TABLE` | TVF tách delimiter regex | **170** (cùng flag TVF) |

```sql
ALTER DATABASE MyDb SET COMPATIBILITY_LEVEL = 170;   -- REGEXP_LIKE / TVF

WHERE REGEXP_LIKE(email, N'^[A-Za-z0-9._%+-]+@', N'i');

SELECT REGEXP_REPLACE(phone, N'[^0-9]', N'');                    -- occurrence mặc định 0 = mọi lần (không cần g)
SELECT REGEXP_REPLACE(name, N'[ae]', N'X', 1, 0, N'i');         -- start, occurrence, flags

SELECT REGEXP_SUBSTR(s, N'(\d+)', 1, 1, N'c', 1);               -- start, occurrence, flags, group
-- không khớp → NULL

SELECT REGEXP_INSTR(s, N'[0-9]+');                              -- vị trí 1-based; 0 nếu không khớp
SELECT REGEXP_INSTR(s, N'a', 1, 3, 0, N'i');                   -- lần 3, return_option 0 = đầu
SELECT REGEXP_INSTR(s, N't.*?e', 1, 1, 1);                      -- return_option 1 = vị trí *cuối* khớp
SELECT REGEXP_COUNT(s, N'\w+');

SELECT * FROM REGEXP_MATCHES(N'Learning #AzureSQL #AzureSQLDB', N'#([A-Za-z0-9_]+)');
-- match_id, start_position, end_position, match_value, substring_matches (json)

SELECT * FROM REGEXP_SPLIT_TO_TABLE(N'the quick brown fox', N'\s+');
-- value, ordinal (bigint, 1-based)
```

`REGEXP_INSTR`: `start ≥ 1`; `start` vượt độ dài → `0`. `return_option` chỉ `0` (đầu) hoặc `1` (cuối). `group` mặc định `0` = cả pattern; `group` lớn hơn số capture → `0`.

`REGEXP_MATCHES` không khớp → **không hàng** (không một hàng NULL). `substring_matches` là JSON mô tả từng capture (`value`, `start`, `length`).

`REGEXP_SPLIT_TO_TABLE` không khớp delimiter → **một hàng** = cả chuỗi, `ordinal = 1`.

RE2: **không** backreference (`\1`), **không** lookahead/lookbehind. Pattern Oracle/PG dùng `(?=…)` / `\1` sẽ lỗi hoặc khác nghĩa — test, đừng copy.

Regex **không** biến `LIKE '%x'` thành sargable. Index: computed persisted / full-text — không có regex index native.

### 3.2 PostgreSQL `regexp_*` / `~`

Lõi `~` / `~*` lâu. Bộ `regexp_like` / `regexp_substr` / `regexp_count` / `regexp_instr` từ **15** (Oracle-compat):

```sql
WHERE email ~ '^[^@]+@'
WHERE email ~* '@contoso\.com$'                 -- * = case-insensitive
WHERE regexp_like(email, '^[^@]+@', 'i');       -- ≡ ~* khi chỉ flag i

SELECT regexp_replace(phone, '[^0-9]', '', 'g');        -- thiếu 'g' → chỉ lần đầu
SELECT regexp_match(s, '[0-9]+');                       -- text[] một lần khớp
SELECT * FROM regexp_matches(s, '(\w+)', 'g');          -- mọi lần; thiếu 'g' → một hàng
SELECT * FROM regexp_split_to_table(s, '\s+');
SELECT regexp_count(s, '\w+');
SELECT regexp_substr(s, '(\d+)', 1, 1, 'i', 1);
SELECT regexp_instr(s, '[0-9]+');
```

Flag PG quen: `g` (global), `i`, `m`/`n` (newline — dialect POSIX PG, **không** giống hệt `s`/`m` SS). `regexp_replace` **bắt buộc** `'g'` nếu muốn thay hết — mặc định một lần.

`regexp_matches` thiếu `'g'` → một hàng dù chuỗi có nhiều khớp. `REGEXP_MATCHES` SS luôn trả mọi lần (không flag `g`).

### 3.3 Port flag & RE2

| Ý | SQL Server 2025 | PostgreSQL |
|---|---|---|
| Thay mọi lần | `REGEXP_REPLACE` occurrence `0` (mặc định) | flag `'g'` |
| Flag `g` | **lỗi** “not valid flags” | bắt buộc nếu muốn global |
| Case-insensitive | `i` | `i` / `~*` |
| `.` khớp newline | `s` | tùy flavor (`n` / `s` — đọc docs `regexp`) |
| `^` `$` theo dòng | `m` | `m` |
| Backref / lookaround | **không** (RE2) | POSIX ARE: backref được; lookaround hạn chế theo phiên bản |
| TVF mọi khớp | `REGEXP_MATCHES` | `regexp_matches(..., 'g')` |

**Ghi chú:** Port `regexp_replace` PG (`'g'`) sang SS: *đừng* thêm flag `g`. Port ngược: *phải* `'g'` nếu muốn thay hết. Unicode property / `\w` / newline **không** portable — test fixture tiếng Việt.

---

## 4. Fuzzy (PREVIEW)

SQL Server **2025 PREVIEW** — cần `ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON`. **Không** production trừ khi chấp nhận đổi CU.

```sql
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;

SELECT
    EDIT_DISTANCE(N'Colour', N'Color'),                          -- int, số phép biến đổi
    EDIT_DISTANCE_SIMILARITY(N'Colour', N'Color'),               -- int 0–100
    JARO_WINKLER_DISTANCE(N'Colour', N'Color'),                  -- float
    JARO_WINKLER_SIMILARITY(N'Colour', N'Color');                -- int 0–100
```

| Hàm | Trả | Ghi chú Learn |
|---|---|---|
| `EDIT_DISTANCE(a, b [, maximum_distance])` | `int` | Damerau–Levenshtein; **hiện không** tính transposition dù tên thuật toán; `varchar(max)`/`nvarchar(max)` **cấm** |
| `EDIT_DISTANCE_SIMILARITY` | `int` 0–100 | `(1 - (edit_distance / greatest(len1,len2))) * 100`; cùng hạn chế transposition / max |
| `JARO_WINKLER_DISTANCE` | `float` | ưu tiên khớp prefix |
| `JARO_WINKLER_SIMILARITY` | `int` 0–100 | |

`NULL` đối số → `NULL`. `maximum_distance ≥ 0` có thể cắt tính; không truyền / âm → khoảng cách thật. Collation-specific comparison **chưa** được honor (docs preview) — đừng giả `CI`/`CS` đổi khoảng cách.

PostgreSQL: **không** bốn tên trên. Extension **`fuzzystrmatch`**: `levenshtein`, `levenshtein_less_equal`, `metaphone`, `dmetaphone`, `soundex` — không phải core 19. `pg_trgm` similarity (`%`, `similarity()`) là họ khác (trigram), không phải Jaro-Winkler.

**Ghi chú:** Fuzzy trên cột trong `WHERE` = scan. Dedup prod: staging + ngưỡng đo, không bật `PREVIEW_FEATURES` “cho vector” kéo fuzzy theo cả database.

---

## 5. Ngày giờ

Kiểu: [typesystem.md](typesystem.md). `datetime` vs `timestamptz` vs `datetimeoffset` lệch timezone — đừng so sánh bằng mắt.

| Việc | SQL Server | PostgreSQL |
|---|---|---|
| Instant local | `SYSDATETIME()`, `GETDATE()` | `clock_timestamp()` / `now()` — **xem §11** |
| UTC | `SYSUTCDATETIME()`, `GETUTCDATE()` | `now() AT TIME ZONE 'UTC'` (sau khi hiểu session TZ) |
| Chỉ ngày | `CURRENT_DATE` (**2025**, kiểu `date`) | `CURRENT_DATE` |
| Cộng | `DATEADD(part, n, d)` — `n` **bigint** (2025) | `d + interval '1 day'` |
| Hiệu | `DATEDIFF` / `DATEDIFF_BIG` | trừ `timestamp` → `interval`; `age()` |
| Cắt | `DATETRUNC` (2022+), `DATE_BUCKET` | `date_trunc`, `date_bin` (14+) |
| Extract | `DATEPART` `YEAR` `MONTH` `DAY` | `extract` / `date_part` |
| Zone | `AT TIME ZONE` | `AT TIME ZONE` (ngữ nghĩa **khác**) |

### 5.1 “Hiện tại” & `CURRENT_DATE`

```sql
-- SQL Server 2025
SELECT CURRENT_DATE;                         -- date, không giờ — ≡ CAST(GETDATE() AS date)
SELECT SYSDATETIME();                        -- datetime2, precision cao
SELECT SYSUTCDATETIME();
SELECT SYSDATETIMEOFFSET();                  -- kèm offset OS
SELECT GETDATE();                            -- datetime, precision ~3.33 ms

-- PostgreSQL
SELECT CURRENT_DATE;                         -- date, STABLE theo mốc txn
SELECT now();                                -- = transaction_timestamp() / CURRENT_TIMESTAMP
SELECT statement_timestamp();
SELECT clock_timestamp();                    -- đổi cả trong một statement
SELECT timeofday();                          -- text, wall clock
```

`CURRENT_DATE` SS: ANSI, lấy ngày hệ thống OS của Database Engine, **nondeterministic** — không indexed view / persisted computed / expression index. Không đối số. PG `CURRENT_DATE` là **STABLE** (cùng giá trị trong txn, đổi txn mới).

Đừng nhầm `CURRENT_DATE` với `GETDATE()` (còn giờ) hay `CURRENT_TIMESTAMP` (SS = `GETDATE` kiểu `datetime`; PG = `now()` timestamptz).

### 5.2 Cộng trừ & trunc — `DATEADD` bigint

Trước 2025, `DATEADD` *number* là **`int`**. `86400 * 10000` giây overflow. **2025** (và Azure SQL / Fabric theo moniker Learn): *number* **`bigint`**.

```sql
-- SQL Server 2025: number là bigint
SELECT DATEADD(second, CAST(86400 AS bigint) * 10000, SYSUTCDATETIME());
SELECT DATEADD(nanosecond, CAST(9000000000000 AS bigint), SYSUTCDATETIME());
SELECT DATETRUNC(month, OrderDate);
SELECT DATEDIFF_BIG(second, '2000-01-01', SYSUTCDATETIME());

-- Tháng ngắn: 31/08 + 1 month → 30/09 (kẹp ngày)
SELECT DATEADD(month, 1, '2024-08-31');

-- PostgreSQL
SELECT timestamp '2024-08-31' + interval '1 month';   -- 2024-09-30
SELECT date_trunc('month', now());
SELECT extract(epoch FROM (now() - ts));              -- giây, double
SELECT now() + make_interval(secs => 864000000);
```

`DATEADD` **cắt** phần thập phân của `number`, không làm tròn. `nanosecond` trên `datetime2` bước **100 ns**. `datepart` là token (`year`,`month`,`second`,…), **không** biến. Không cộng timezone offset bằng `DATEADD`.

Port vòng lặp “cộng N giây lớn” từ SS 2019: đổi kiểu `int` → `bigint` *và* engine 2025; giữ compat 160 trên 2025 vẫn nhận `bigint` `DATEADD` (đây là parser/engine, không phải IQP 170).

### 5.3 `AT TIME ZONE`

```sql
-- SQL Server: datetime2 không offset = wall-clock zone nguồn rồi chuyển
SELECT CONVERT(datetime2, '2026-09-13 12:00:00')
       AT TIME ZONE 'SE Asia Standard Time'
       AT TIME ZONE 'UTC';

-- datetimeoffset: chuyển zone, giữ instant
SELECT SYSDATETIMEOFFSET() AT TIME ZONE 'UTC';

-- PostgreSQL: timestamp AT TIME ZONE gắn zone → timestamptz
--             timestamptz AT TIME ZONE bỏ zone → timestamp
SELECT timestamp '2026-09-13 12:00:00' AT TIME ZONE 'Asia/Ho_Chi_Minh';
SELECT now() AT TIME ZONE 'UTC';
```

**Ghi chú:** `AT TIME ZONE` copy nguyên giữa hai engine = lệch giờ. Tên zone SS = Windows (`SE Asia Standard Time`); PG = IANA (`Asia/Ho_Chi_Minh`). DST: test ngày chuyển giờ.

---

## 6. Aggregate

Cả hai: `SUM` `AVG` `MIN` `MAX` `COUNT` `COUNT(*)`. `MIN`/`MAX` bỏ NULL. Nhóm rỗng (không `GROUP BY`, 0 hàng): `COUNT(*)` = 0; `SUM`/`AVG`/`MIN`/`MAX` = `NULL`.

### 6.1 `COUNT` / `SUM` / `AVG`

```sql
COUNT(*)                 -- mọi hàng, kể cả cột NULL
COUNT(col)               -- bỏ NULL col
COUNT(DISTINCT col)      -- DISTINCT + NULL: NULL không đếm

SELECT AVG(n) FROM (VALUES (1), (2), (NULL)) AS t(n);   -- 1.5, không chia 3
```

`AVG` integer SS: chia nguyên rồi lên kiểu kết quả — `AVG` của `int` có thể **cắt**. PG `avg(int)` → `numeric`. Tiền tệ: `AVG(CAST(n AS decimal(19,4)))`.

`STRING_AGG` / `string_agg`: §2. Ordered-set PG:

```sql
SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY total) FROM orders;  -- median, gộp hàng
SELECT mode() WITHIN GROUP (ORDER BY status);
```

SQL Server `PERCENTILE_CONT` / `PERCENTILE_DISC` là **window** (giữ hàng, bắt buộc `OVER`) — không gộp. Đừng copy `WITHIN GROUP` PG vào SS rồi quên `OVER`, và đừng mong PG `percentile_cont` giữ từng hàng.

### 6.2 `PRODUCT()`

SQL Server **2025** — nhân mọi giá trị numeric (**trừ `bit`**). Bỏ NULL. `ALL` mặc định; `DISTINCT` được. Aggregate và analytic (`OVER`).

```sql
SELECT sku, PRODUCT(factor) AS compounded
FROM dbo.Rates
GROUP BY sku;

SELECT sku, PRODUCT(DISTINCT factor)
FROM dbo.Rates
GROUP BY sku;

SELECT finInstrument,
       PRODUCT(1 + rateOfReturn) OVER (PARTITION BY finInstrument) AS CompoundedReturn
FROM dbo.Returns;
```

Kiểu trả: `tinyint`/`smallint`/`int` → `int`; `bigint` → `bigint`; `decimal` → `decimal(38,0)` nếu scale 0, không thì `decimal(38,6)`; `money`/`smallmoney` → `money`; `float`/`real` → `float`. Overflow → lỗi. Deterministic khi đối số deterministic.

PostgreSQL **19 không** có `PRODUCT()`. Công thức dương:

```sql
SELECT exp(sum(ln(factor))) FROM rates WHERE factor > 0;
```

Zero/âm phá `ln`. Cần dấu/zero: `CREATE AGGREGATE` tùy biến, hoặc nhân trong recursive/CTE. Đừng bịa `product()` built-in trên PG.

**Ghi chú:** `PRODUCT` cửa sổ vẫn phụ thuộc frame — running product cần `ROWS` tường minh như `SUM`: [window-functions.md](window-functions.md).

### 6.3 `FILTER`

PostgreSQL (aggregate và *aggregate-as-window*):

```sql
SELECT
    SUM(total) FILTER (WHERE status = 'paid')   AS paid,
    SUM(total) FILTER (WHERE status = 'open')   AS open_amt,
    COUNT(*)   FILTER (WHERE total > 100)       AS big
FROM orders;

SELECT SUM(total) FILTER (WHERE status = 'paid')
       OVER (PARTITION BY customer_id)
FROM orders;
```

SQL Server **không** có `FILTER`. Viết:

```sql
SUM(CASE WHEN status = 'paid' THEN total END)
COUNT(CASE WHEN total > 100 THEN 1 END)
```

`SUM(CASE WHEN … THEN total ELSE 0 END)` đổi ngữ nghĩa khi *mọi* hàng lọc hết: `FILTER`/`CASE` không `ELSE` → `NULL`; `ELSE 0` → `0`. Chọn cố ý.

**Ghi chú:** `FILTER` trên window **chỉ** hàm aggregate. `LAG(x) FILTER (WHERE …)` không hợp lệ — dùng `IGNORE NULLS` / `CASE` trong argument.

---

## 7. Điều kiện

```sql
COALESCE(a, b, c)            -- đối số đầu không NULL; dừng (không eval phần sau — trên lý thuyết SQL;
                             -- UDF trong đối số sau vẫn có thể được gọi tùy optimizer)
NULLIF(a, b)                 -- a = b → NULL; else a. NULL = NULL → UNKNOWN → không thành NULL
GREATEST(a, b, c)            -- SS 2022+ (≤254 đối số); PG lâu
LEAST(a, b, c)

CASE WHEN x > 0 THEN 1 WHEN x = 0 THEN 0 ELSE -1 END     -- searched
CASE x WHEN 1 THEN 'a' ELSE 'b' END                      -- simple; x = NULL không khớp WHEN NULL

-- SQL Server
IIF(x > 0, 1, 0)             -- ≡ CASE WHEN x > 0 THEN 1 ELSE 0 END
CHOOSE(2, 'a', 'b', 'c')     -- 'b'
```

`GREATEST` / `LEAST` **bỏ NULL** trên *cả hai* engine; tất cả NULL → `NULL`. Đây **lệch SQL standard** (standard: một NULL → NULL, kiểu Oracle). Port từ Oracle phải viết `CASE`.

Kiểu kết quả `COALESCE` = precedence / type conversion chung — `COALESCE(int, decimal)` lên decimal. Lẫn `datetime` / `varchar` → lỗi hoặc ép bất ngờ.

**Ghi chú:** `NULLIF(x, 0)` trước chia. `COALESCE(x, y)` không thay `IS DISTINCT FROM` khi cần phân biệt NULL với giá trị. Simple `CASE` không viết `WHEN NULL`.

---

## 8. `CAST` / `TRY_CAST`

```sql
CAST(x AS int)
CAST(x AS decimal(12,2))

-- SQL Server
CONVERT(int, x)
CONVERT(varchar(10), d, 23)              -- style 23: yyyy-mm-dd
TRY_CAST(x AS int)                       -- fail → NULL, không abort batch
TRY_CONVERT(int, x)
TRY_PARSE(N'13/09/2026' AS date USING 'en-GB')

-- PostgreSQL
CAST(x AS int)
x::int                                   -- cùng CAST; precedence cao
x::date
```

PostgreSQL **không** có `TRY_CAST`. Fail → statement error (txn abort trừ savepoint). Pattern:

```sql
-- PG: kiểm tra trước
SELECT CASE WHEN s ~ '^[0-9]+$' THEN s::int END;

-- PL/pgSQL
BEGIN
    v := s::int;
EXCEPTION WHEN invalid_text_representation THEN
    v := NULL;
END;
```

`CONVERT` style **không** portable. ISO: `CAST` + kiểu `date`/`timestamptz`. `varchar` không length trên PG; SS `varchar` không length = `varchar(1)` (bẫy cổ) — [typesystem.md](typesystem.md).

**Ghi chú:** `TRY_CAST` nuốt dữ liệu bẩn thành NULL — báo cáo “mất hàng” thường là convert fail, không phải `WHERE`. Log `WHERE TRY_CAST(s AS int) IS NULL AND s IS NOT NULL`.

---

## 9. Vector & AI

SQL Server **2025** kiểu `vector(n)` (tối đa **1998** dim, mặc định float32). Lưu binary, expose JSON array. Distance **exact** — `VECTOR_DISTANCE` **không** dùng vector index dù có.

### 9.1 `VECTOR_DISTANCE` / `NORM` / `NORMALIZE` / `PROPERTY`

```sql
DECLARE @q vector(1536) = '[0.1, 0.2, 0.3]';   -- literal JSON array
DECLARE @a vector(2) = '[1, 1]';
DECLARE @b vector(2) = '[-1, -1]';

SELECT VECTOR_DISTANCE('cosine', @a, @b);       -- [0, 2]; 0 = trùng hướng, 2 = ngược
SELECT VECTOR_DISTANCE('euclidean', @a, @b);    -- [0, +∞)
SELECT VECTOR_DISTANCE('dot', @a, @b);          -- *âm* dot product; nhỏ hơn = giống hơn

SELECT VECTOR_NORM(@q, 'norm2');                -- Euclidean; bắt buộc norm_type
SELECT VECTOR_NORM(@q, 'norm1');                -- tổng |x_i|
SELECT VECTOR_NORM(@q, 'norminf');              -- max |x_i|

SELECT VECTOR_NORMALIZE(@q, 'norm2');           -- cùng hướng, độ dài 1 theo norm
SELECT VECTOR_NORMALIZE(@q, 'norm1');
SELECT VECTOR_NORMALIZE(@q, 'norminf');

SELECT VECTORPROPERTY(@q, 'Dimensions');        -- int
SELECT VECTORPROPERTY(@q, 'BaseType');          -- sysname (mặc định float32)
```

`VECTOR_DISTANCE(metric, v1, v2)`: metric chỉ `'cosine'` | `'euclidean'` | `'dot'`. Sai metric / không phải kiểu `vector` → lỗi. Exact search:

```sql
SELECT TOP (10) id, title,
       VECTOR_DISTANCE('cosine', @q, title_vector) AS distance
FROM dbo.wikipedia_articles
ORDER BY distance;

SELECT id, title,
       VECTOR_DISTANCE('cosine', @q, title_vector) AS distance
FROM dbo.wikipedia_articles
WHERE VECTOR_DISTANCE('cosine', @q, title_vector) < 0.3
ORDER BY distance;
```

`VECTOR_NORM` / `VECTOR_NORMALIZE` **bắt buộc** `norm_type`. Không có overload một đối số — đừng copy `VECTOR_NORM(@q)` từ blog.

**PREVIEW** (`PREVIEW_FEATURES`): `CREATE VECTOR INDEX` (DiskANN), `VECTOR_SEARCH` (ANN). Catalog `sys.vector_indexes`. Exact ≠ ANN. Cú pháp `VECTOR_SEARCH` đối chiếu Learn theo CU. `float16` vector cũng **PREVIEW**.

### 9.2 `AI_GENERATE_*`

Embedding từ model **đăng ký trong DB**, không phải URL nhét hàm:

```sql
CREATE EXTERNAL MODEL Ada2Embeddings
WITH (
    LOCATION    = N'https://my-endpoint.cognitiveservices.azure.com/openai/deployments/text-embedding-ada-002/embeddings?api-version=2023-05-15',
    API_FORMAT  = 'Azure OpenAI',          -- Azure OpenAI | OpenAI | Ollama | ONNX Runtime
    MODEL_TYPE  = EMBEDDINGS,              -- hiện chỉ EMBEDDINGS
    MODEL       = 'text-embedding-ada-002',
    CREDENTIAL  = [https://my-endpoint.cognitiveservices.azure.com/],
    PARAMETERS  = '{"dimensions":1536}'    -- JSON tùy chọn
);

SELECT AI_GENERATE_EMBEDDINGS(N'Pink Floyd' USE MODEL Ada2Embeddings);

DECLARE @params json = N'{"dimensions":768}';
SELECT AI_GENERATE_EMBEDDINGS(body USE MODEL Ada2Embeddings PARAMETERS @params)
FROM dbo.Doc;

INSERT INTO dbo.DocEmb (chunk, embedding)
SELECT c.chunk,
       AI_GENERATE_EMBEDDINGS(c.chunk USE MODEL Ada2Embeddings)
FROM dbo.Doc AS d
CROSS APPLY AI_GENERATE_CHUNKS(
    SOURCE     = d.body,
    CHUNK_TYPE = FIXED,
    CHUNK_SIZE = 100
) AS c;
```

`CREATE EXTERNAL MODEL` / `ALTER` / `DROP`: DDL, quyền riêng — chi tiết [routines.md](routines.md). Gọi HTTP: timeout, credential (database scoped / managed identity), không hard-code key. REST thủ công: `sp_invoke_external_rest_endpoint` (cùng file routines).

Không gọi `AI_GENERATE_EMBEDDINGS` per-row trong trigger OLTP.

### 9.3 pgvector

PostgreSQL **19 không** có kiểu vector lõi, **không** `VECTOR_DISTANCE` / `VECTOR_NORM` / `AI_GENERATE_*`. Extension **pgvector**: kiểu `vector`, operator `<->` (L2), `<=>` (cosine), `<#>` (negative inner product), hàm `cosine_distance`, `l2_normalize`, IVFFlat/HNSW. Hybrid search = vector + full-text — hai điểm số, không một hàm.

**Ghi chú:** Dim embedding phải khớp cột `vector(n)` / pgvector. Model `text-embedding-3-small` 1536 ≠ cột 768. Cosine SS là *distance* `[0,2]`; một số thư viện trả *similarity* `[−1,1]` — đừng so ngưỡng chéo.

---

## 10. System

```sql
-- SQL Server
SELECT DB_NAME(), SCHEMA_NAME(), OBJECT_NAME(object_id);
SELECT SUSER_SNAME(), USER_NAME(), ORIGINAL_LOGIN();
SELECT @@SPID, @@ROWCOUNT, @@TRANCOUNT, @@IDENTITY, SCOPE_IDENTITY();
SELECT ERROR_NUMBER(), ERROR_MESSAGE(), ERROR_LINE();   -- trong CATCH
SELECT SERVERPROPERTY('ProductVersion'), DATABASEPROPERTYEX(DB_NAME(), 'Updateability');

-- PostgreSQL
SELECT current_database(), current_schema(), current_user, session_user;
SELECT current_setting('search_path'), pg_backend_pid();
SELECT xmin, xmax, ctid FROM t LIMIT 1;
SELECT pg_current_xact_id_if_assigned();               -- NULL nếu chưa xin xid
```

`@@ROWCOUNT` = số hàng statement **vừa xong** — `SET NOCOUNT ON` không xóa `@@ROWCOUNT`, chỉ thôi gửi DONE client. Gọi hàm scalar giữa chừng có thể đổi `@@ROWCOUNT`. PG không có `@@ROWCOUNT`; `GET DIAGNOSTICS … ROW_COUNT` trong PL/pgSQL.

`SCOPE_IDENTITY()` vs `@@IDENTITY` vs `IDENT_CURRENT`: trigger chèn bảng khác làm `@@IDENTITY` lệch — dùng `SCOPE_IDENTITY()` hoặc `OUTPUT`. PG: `RETURNING id` / `lastval()` / `currval(seq)` — `lastval` session-wide.

PG 19 thêm một số hàm tiện (`encode` format mới §2.4; `random(min,max)` cho date/timestamp; `bytea`↔`uuid`; `error_on_null()`; `tid_block()` / `tid_offset()`; `pg_get_role_ddl()` …) — dùng khi cần, không nhét mọi API vào app.

**Ghi chú:** `txid_current()` / `pg_current_xact_id()` **gán xid** nếu chưa có. Monitoring: bản `*_if_assigned`. [transactions.md](transactions.md).

---

## 11. Determinism: `now()` vs `clock_timestamp()`

**Hình dung hai đồng hồ.**

PostgreSQL `now()` = đồng hồ **treo lúc `BEGIN`**. Ngủ 5 giây, `now()` vẫn giờ mở txn — mọi hàng `INSERT` trong txn đó cùng mốc. `clock_timestamp()` = đồng hồ tường: mỗi lần gọi một số khác, kể cả trong một `SELECT`.

SQL Server `SYSDATETIME()` **không** treo lúc `BEGIN TRAN`. Cùng txn, câu sau có thể muộn hơn câu trước. Đừng port `DEFAULT now()` thành “luôn một instant cả txn” trên T-SQL mà không gán biến `@t` lúc mở.

Hàm đổi mỗi lần gọi (`random`, `NEWID`, `clock_timestamp`) **không** được làm cột computed persisted / expression index: index sẽ sai so với lần đọc sau.

Hàm **nondeterministic** không dùng trong persisted computed, expression index (PG `IMMUTABLE`), indexed view (SS còn SET options).

| Nguồn | Ổn trong txn? | Ổn trong statement? | Nhãn / catalog |
|---|---|---|---|
| PG `now()` / `CURRENT_TIMESTAMP` / `transaction_timestamp()` | **có** — mốc **bắt đầu txn** | có | `STABLE` |
| PG `CURRENT_DATE` / `CURRENT_TIME` | có (cùng mốc txn) | có | `STABLE` |
| PG `statement_timestamp()` | không (đổi mỗi statement) | có | `STABLE` theo statement |
| PG `clock_timestamp()` | không | **không** — đổi giữa các hàng / vòng lặp PL | `VOLATILE` |
| PG `timeofday()` | không | không | `VOLATILE`, trả `text` |
| PG `random()` / `gen_random_uuid()` | không | không | `VOLATILE` |
| SS `GETDATE` / `SYSDATETIME` / `CURRENT_TIMESTAMP` / `CURRENT_DATE` | catalog **nondeterministic** | thường một lần / query (không hợp đồng STABLE như PG) | **Không** PK uniqueness |
| SS `NEWID()` / `NEWSEQUENTIALID()` / `CRYPT_GEN_RANDOM` / `RAND()` không seed | không | không | |

```sql
-- PostgreSQL: cùng txn, ba now() bằng nhau; hai clock_timestamp() có thể khác
BEGIN;
SELECT now(), now(), clock_timestamp();
SELECT pg_sleep(0.05);
SELECT now(), clock_timestamp();     -- now() vẫn mốc BEGIN; clock đã chạy
COMMIT;

-- Đo latency trong một statement (cùng hàng / SRF)
SELECT clock_timestamp() AS t0, pg_sleep(0.01), clock_timestamp() AS t1;

-- Default cột “lúc tạo”
-- PG: DEFAULT now()               — đúng (STABLE, mọi hàng INSERT cùng statement/txn cùng mốc)
-- PG: DEFAULT clock_timestamp()   — mỗi hàng một instant; hiếm khi cần; không IMMUTABLE
-- SS: DEFAULT SYSDATETIME()       — phổ biến
-- SS: DEFAULT NEWID()             — GUID; phân tán index nếu clustered
```

`now()` **không** đổi trong stored function cùng txn — đó là điểm, không phải bug. Muốn “thời điểm thật lúc hàng này ghi” (audit từng row trong `INSERT…SELECT` dài, hoặc đo hàm): `clock_timestamp()`. Muốn idempotent / cùng batch cùng stamp: `now()` / `SYSDATETIME`.

`now()` làm khóa nghiệp vụ / “microsecond unique” **sai**. Dùng sequence / `uniqueidentifier` / `uuid`.

SQL Server: `RAND(seed)` deterministic theo seed; `RAND()` không seed = một giá trị **mọi hàng** trong query (bẫy). Muốn mỗi hàng: `CRYPT_GEN_RANDOM` hoặc `ABS(CHECKSUM(NEWID()))`.

Expression index PG bắt `IMMUTABLE`. Gắn `IMMUTABLE` lên hàm gọi `now()` / `clock_timestamp()` = **bug im lặng** (index không cập nhật theo đồng hồ). `STABLE` được trong index? **Không** — chỉ `IMMUTABLE`. [routines.md](routines.md).

**Ghi chú:** So `clock_timestamp() - now()` trong cùng statement = thời gian từ lúc *bắt đầu txn* (có thể lâu nếu txn mở sớm), không phải “duration câu SQL”. Session `BEGIN` rồi nghĩ 5 phút rồi `SELECT clock_timestamp() - now()` ≈ 5 phút.

---

## 12. Worked examples

**Chuẩn hóa điện thoại + Base64 token**

```sql
-- SQL Server 2025
SELECT
    REGEXP_REPLACE(phone, N'[^0-9]', N'') AS digits,
    BASE64_ENCODE(HASHBYTES('SHA2_256', CAST(email AS varbinary(4000))), 1) AS tok;

-- PostgreSQL 19
SELECT
    regexp_replace(phone, '[^0-9]', '', 'g') AS digits,
    encode(digest(email, 'sha256'), 'base64url') AS tok;   -- digest: pgcrypto
```

**Compounded return**

```sql
-- SQL Server 2025
SELECT instrument, PRODUCT(1.0 + r) AS growth
FROM dbo.Returns
GROUP BY instrument;

-- PostgreSQL: chỉ factor > 0
SELECT instrument, exp(sum(ln(1.0 + r))) AS growth
FROM returns
WHERE 1.0 + r > 0
GROUP BY instrument;
```

**Exact k-NN**

```sql
DECLARE @q vector(1536) = AI_GENERATE_EMBEDDINGS(N'Pink Floyd' USE MODEL Ada2Embeddings);

SELECT TOP (5) id,
       VECTOR_DISTANCE('cosine', embedding, VECTOR_NORMALIZE(@q, 'norm2')) AS dist
FROM dbo.DocEmb
ORDER BY dist;
```

Chuẩn hóa query nếu model không L2-normalize. Cột đã normalize: cosine và (âm) dot cùng thứ tự trên sphere đơn vị — vẫn ghi metric tường minh.

**LOCF thời gian — hàm offset, không regex**

[window-functions.md](window-functions.md) `LAST_VALUE … IGNORE NULLS`. Đừng `REGEXP` để “tìm giá trị trước”.

---

## 13. Best practices & checklist

- Scalar trên cột trong `WHERE` → computed persisted / cột gốc / `LIKE` sargable.
- Nối: `CONCAT` / `CONCAT_WS` / `||`; đừng `+` T-SQL với số.
- Regex: flag `g` chỉ PG; SS RE2 không backref; compat 170 cho `REGEXP_LIKE` / TVF.
- Fuzzy / vector index / `VECTOR_SEARCH`: PREVIEW — lab.
- Thời gian: lưu UTC (`datetimeoffset` / `timestamptz`); `CURRENT_DATE` chỉ khi đúng nghĩa “ngày session”.
- `DATEADD` 2025 mới nhận `bigint` — port vòng lặp giây lớn từ `int`.
- Aggregate NULL: biết `SUM` = NULL vs `COALESCE(SUM(x),0)`.
- `PRODUCT` chỉ SS 2025; PG không bịa tên.
- `FILTER` chỉ PG; SS dùng `CASE` không `ELSE 0` nếu muốn NULL khi không hàng.
- Convert bẩn: `TRY_CAST` + báo cáo reject; PG kiểm tra regex trước khi `::`.
- Vector: `VECTOR_DISTANCE` exact; `VECTOR_NORM`/`NORMALIZE` có `norm_type`. Model ngoài = mạng.
- Default thời gian: `now()` / `SYSDATETIME`; `clock_timestamp()` khi cần wall-clock trong statement.
- System: `SCOPE_IDENTITY` / `RETURNING`, không `@@IDENTITY`.
- Base64 URL: SS `url_safe=1` / PG `'base64url'` (19) — test padding.

```text
□ LEN vs DATALENGTH / length vs octet_length đúng ý
□ STRING_AGG có ORDER BY
□ REGEXP flag portable; không g trên SS
□ DATEADD không overflow int trên bản cũ
□ GREATEST bỏ NULL — khớp nghiệp vụ?
□ TRY_CAST không nuốt lỗi im lặng trên biên API
□ Hàm VOLATILE không nằm expression index
□ VECTOR_NORM có norm_type
□ PREVIEW_FEATURES không bật prod “cho một hàm”
```

---

## 14. Bẫy khi review

- `LEN` “thiếu” space cuối.
- `'a' + NULL` vs `CONCAT`.
- `STRING_SPLIT` không ordinal rồi `JOIN` theo thứ tự.
- `regexp_replace` thiếu `'g'` trên PG.
- Flag `g` trên `REGEXP_REPLACE` SS.
- `REGEXP_LIKE` / `REGEXP_MATCHES` trên DB compat < 170.
- Pattern lookaround/backref (RE2).
- `DATEADD(second, 86400*20000, …)` overflow `int` trước 2025.
- `AT TIME ZONE` copy nguyên giữa hai engine.
- `AVG(int)` cắt trên SS.
- `PRODUCT` giả trên PostgreSQL.
- `FILTER` giả trên SQL Server.
- `PERCENTILE_CONT` PG gộp hàng / SS window.
- `GREATEST` nghĩ như Oracle (NULL thắng).
- `TRY_CAST` biến rác thành NULL, báo cáo lệch.
- `::timestamp` vs `timestamptz` session TZ.
- `now()` vs `clock_timestamp()` trong cùng statement đo latency.
- `IMMUTABLE` bọc `now()`.
- `NEWID()` trong `WHERE` / computed.
- `RAND()` “mỗi hàng một số”.
- `@@IDENTITY` sau trigger.
- `VECTOR_NORM(@q)` thiếu `'norm2'`.
- `VECTOR_SEARCH` production khi còn PREVIEW.
- `EDIT_DISTANCE` trên `nvarchar(max)` / không `PREVIEW_FEATURES`.
- `encode(..., 'base64url')` trên PG 18.
- Gọi `AI_GENERATE_EMBEDDINGS` per-row trong trigger OLTP.
- `UNISTR` trên collation legacy code page.

---

## 15. Version gates

| Mục | SQL Server | PostgreSQL |
|---|---|---|
| `REGEXP_*` native (RE2) | **2025** (`LIKE` TVF / `REGEXP_LIKE`: compat **170**) | `~` lâu; `regexp_like` **15+** |
| Fuzzy `EDIT_DISTANCE`… | **2025 PREVIEW** | `fuzzystrmatch` ext |
| `SUBSTRING` length optional | **2025** | lâu (`FROM n`) |
| `CURRENT_DATE` | **2025** | lõi |
| `DATEADD` `bigint` | **2025** | `interval` |
| `DATETRUNC` / `DATE_BUCKET` | **2022+** | `date_trunc` / `date_bin` **14+** |
| `PRODUCT()` | **2025** | — |
| `FILTER` aggregate | — | lõi |
| `GREATEST` / `LEAST` | **2022+** | lõi |
| `TRY_CAST` | 2012+ | — |
| `STRING_SPLIT` ordinal | **2022+** | `unnest` + `ordinality` |
| `\|\|` nối chuỗi | **2022+** | lõi |
| `UNISTR` | **2025** | `U&` / `chr` |
| `BASE64_ENCODE`/`DECODE` | **2025** (`url_safe`) | `encode`/`decode`; **`base64url` / `base32hex` = 19** |
| `vector` / `VECTOR_DISTANCE` / `NORM` / `NORMALIZE` / `PROPERTY` | **2025** | pgvector ext |
| `AI_GENERATE_EMBEDDINGS` / `CHUNKS` / `CREATE EXTERNAL MODEL` | **2025** | — (app / ext) |
| `VECTOR_SEARCH` / vector index | **2025 PREVIEW** | pgvector IVFFlat/HNSW |
| Window `IGNORE NULLS` | **2022+** | **19** |

Window, CTE, routine (REST, definer, TVF): [window-functions.md](window-functions.md), [cte-subqueries.md](cte-subqueries.md), [routines.md](routines.md). Kiến trúc: [internal.md](internal.md).

---

## Phụ lục A. Sargable & collation

Hàm trên **cột** trong `WHERE`/`JOIN` thường phá index seek: `WHERE YEAR(d) = 2026`, `WHERE LOWER(email) = N'a@b'`, `WHERE REGEXP_LIKE(sku, N'^ABC')`. Viết `d >= '2026-01-01' AND d < '2027-01-01'`; collation case-insensitive thay `LOWER`; prefix `LIKE 'ABC%'` thay regex neo đầu nếu đủ.

Computed persisted + index (SS) / expression index `IMMUTABLE` (PG) khi phải giữ hàm. `REGEXP_LIKE` không sargable — không có regex index native SS. PG `~` dùng index trigram (`pg_trgm`) hoặc không — đo `EXPLAIN`.

Collation: `LIKE` / `=` / `UPPER` theo collation cột. `UNISTR` trên `varchar` cần UTF-8 collation. Fuzzy preview **không** honor collation — so byte/logic riêng, test tiếng Việt.

`CAST(col AS date)` trên `datetime` SS có thể vẫn seek tùy convert; `CONVERT(varchar, d, 23) = '2026-09-13'` thì không. PG `ts::date` phá index `timestamptz` trừ khi range tường minh.

Compat 170: `REGEXP_LIKE` / TVF. Engine 2025 + compat 160: scalar `REGEXP_REPLACE`/`SUBSTR`/`INSTR`/`COUNT` vẫn chạy; TVF cần 170 hoặc `ALLOW_BUILTIN_TVF_IN_ALL_COMPAT_LEVELS`. Đừng nâng 170 chỉ vì một `REGEXP_LIKE` nếu chưa baseline Query Store — [internal.md](internal.md).
