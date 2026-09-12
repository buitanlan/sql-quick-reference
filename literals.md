# Literal

> **Baseline:** SQL Server **2025** · PostgreSQL **19**.

Literal là giá trị viết trong câu lệnh — parser gắn *kiểu* (hoặc *unknown*) trước khi so với cột. Sai literal không phải lỗi cú pháp: `'2026-09-13'` có thể là `varchar`, `date`, hoặc `datetime` tùy engine, `DATEFORMAT`, và ngữ cảnh. PostgreSQL cố tình để chuỗi untyped (`unknown`) đến khi neo; SQL Server chọn `varchar`/`nvarchar` ngay theo prefix `N` và collation. Hiểu lớp này trước khi debug “sao parameter không khớp” / “sao ngày đảo tháng”.

Kiểu sau khi neo: [typesystem.md](typesystem.md). Escape identifier (không phải literal): [dialects.md](dialects.md). Session `standard_conforming_strings` / TDS: [dialects.md](dialects.md) §10.

---

## Mục lục

- [1. Tổng quan \& triết lý](#1-tổng-quan--triết-lý)
- [2. Số](#2-số)
  - [2.1 Integer \& kiểu suy ra](#21-integer--kiểu-suy-ra)
  - [2.2 Hex \& binary số](#22-hex--binary-số)
  - [2.3 Float / scientific](#23-float--scientific)
- [3. Chuỗi](#3-chuỗi)
  - [3.1 Nháy đơn](#31-nháy-đơn)
  - [3.2 Prefix `N` (SQL Server)](#32-prefix-n-sql-server)
  - [3.3 Backslash \& `E'…'` (PostgreSQL)](#33-backslash--e-postgresql)
- [4. Unicode \& escape](#4-unicode--escape)
- [5. Binary / bit / BASE64](#5-binary--bit--base64)
- [6. Ngày giờ](#6-ngày-giờ)
  - [6.1 Typed literal vs chuỗi](#61-typed-literal-vs-chuỗi)
  - [6.2 `DATEFORMAT` / language](#62-dateformat--language)
  - [6.3 `interval` (PostgreSQL)](#63-interval-postgresql)
- [7. Boolean, NULL](#7-boolean-null)
- [8. Array, row, JSON](#8-array-row-json)
- [9. Dollar-quoting (PostgreSQL)](#9-dollar-quoting-postgresql)
- [10. Typed literal, unknown, parameter](#10-typed-literal-unknown-parameter)
- [11. ODBC escape (SQL Server)](#11-odbc-escape-sql-server)
- [12. Dump PG 19 — `standard_conforming_strings`](#12-dump-pg-19--standard_conforming_strings)
- [13. Hai session — ví dụ làm việc](#13-hai-session--ví-dụ-làm-việc)
- [14. Best practices \& checklist](#14-best-practices--checklist)
- [15. Bẫy khi review](#15-bẫy-khi-review)
- [16. Version gates](#16-version-gates)
- [Phụ lục A. `UNISTR` doubling](#phụ-lục-a-unistr--doubling--trong-t-sql)
- [Phụ lục B. COPY / bcp vs SQL literal](#phụ-lục-b-copy--bcp-vs-sql-literal)
- [Phụ lục C. Regex pattern như literal](#phụ-lục-c-regex-pattern-như-literal)
- [Phụ lục D. Mix literal và parameter](#phụ-lục-d-mix-literal-và-parameter--estimate)
- [Phụ lục E. `json_array()` vs `JSON_ARRAY`](#phụ-lục-e-json_array-vs-json_array-vs-json_agg)

---

## 1. Tổng quan & triết lý

Literal **không** phải constant kiểu C# `const`: giá trị biết lúc parse, nhưng kiểu có thể phụ thuộc session (`DATEFORMAT`, collation, `standard_conforming_strings`). Parameter (`@id`, `$1`) *không* phải literal — client gắn kiểu riêng; mix literal và parameter trong một biểu thức dễ ra plan/estimate lệch.

Không có digit separator `1_000` (C#). Không có suffix `L`/`M`/`D`. Độ lớn / dấu chấm / scientific notation quyết định kiểu.

```sql
42              -- integer (cả hai, với điều kiện độ lớn — §2)
3.14            -- numeric / decimal, không phải float
1.2e-3          -- float (SQL Server) / double precision (PostgreSQL)
'O''Brien'      -- chuỗi; nháy đơn nhân đôi
NULL            -- untyped; lấy kiểu từ ngữ cảnh
```

**Ghi chú:** PG 19 **cắt** khả năng `SET standard_conforming_strings = off`. Literal `'…'` với `\` đổi nghĩa so dump 18 — §12. SQL Server 2025 thêm `UNISTR` / `BASE64_*` — hàm trên chuỗi/binary, không token literal mới kiểu `0b`.

---

## 2. Số

### 2.1 Integer & kiểu suy ra

```sql
-- SQL Server: literal nguyên không dấu → int nếu vừa 32-bit có dấu; lớn hơn → numeric
SELECT SQL_VARIANT_PROPERTY(2147483647, 'BaseType');   -- int
SELECT SQL_VARIANT_PROPERTY(2147483648, 'BaseType');   -- numeric
SELECT SQL_VARIANT_PROPERTY(-2147483648, 'BaseType');  -- int

-- PostgreSQL: untyped numeric literal chọn theo ngữ cảnh; đứng một mình:
SELECT pg_typeof(1);       -- integer
SELECT pg_typeof(1.0);     -- numeric
SELECT pg_typeof(1e0);     -- double precision
```

Trước / sau — overflow im lặng vs lỗi:

```sql
-- SQL Server: literal quá int đã là numeric, không overflow lúc parse
SELECT 2147483648;                         -- numeric

-- Gán vào int mới overflow
DECLARE @i int = 2147483648;               -- lỗi Arithmetic overflow
```

```sql
-- PostgreSQL
SELECT 2147483648;                         -- integer? không — bigint (vừa int8)
SELECT 9223372036854775808;                -- numeric (lớn hơn int8)
```

**Ghi chú:** Không viết `1_000`. Dấu `+`/`-` unary gắn với token. `(2147483648)` vẫn numeric trên SQL Server. Chia `1/2` = 0 (integer) — [operators.md](operators.md). `PRODUCT(2)` không phải literal; aggregate — [typesystem.md](typesystem.md).

### 2.2 Hex & binary số

```sql
-- SQL Server: 0x… là varbinary literal, KHÔNG phải integer hex
SELECT 0xFF;                               -- 0xFF (1 byte)
SELECT CAST(0xFF AS int);                  -- 255
-- SELECT 0xFFFFFFFFFF AS int              -- overflow/cắt tùy CAST

-- PostgreSQL: 0x không phải integer hex trong SQL lõi (khác JavaScript)
-- Integer hex: dùng CAST / bit string, không 0xFF kiểu T-SQL
SELECT x'FF'::bytea;                       -- một dạng
SELECT '\xFF'::bytea;
SELECT CAST('FF' AS bytea);                -- encode khác — đừng nhầm hex ASCII
```

SQL Server `0x` rỗng = `varbinary` empty. Dùng cho so sánh binary / blob, không làm cờ số trừ khi `CAST`.

Không có literal `0b1010` kiểu C. PG `B'1010'` là **bit string**, không phải integer cho đến `::int`.

### 2.3 Float / scientific

```sql
SELECT 1.2e-3;
SELECT 1e0;
SELECT 1.;                                 -- numeric 1.0 (có dấu chấm → không còn int)
```

SQL Server: `1e0` → `float` (cụ thể `float(53)`). `1.0` → `numeric`. Trộn `1 + 1e0` promote float — mất chính xác tiền tệ.

PostgreSQL: `1e0` → `double precision`. `1.0` → `numeric`. `'NaN'::numeric` / `'Infinity'::float8` là **chuỗi typed**, không phải token số — [typesystem.md](typesystem.md).

Vector literal phía client thường JSON array text rồi cast — `'[0.1, 0.2]'` là chuỗi, không token `vector`. — [typesystem.md](typesystem.md) §10.

---

## 3. Chuỗi

### 3.1 Nháy đơn

Cả hai: chuỗi trong `'…'`. Escape nháy đơn bằng **nhân đôi**.

```sql
SELECT 'O''Brien';                         -- O'Brien
SELECT 'it''s';                            -- it's
```

Nháy kép `"…"` **không** phải chuỗi khi quoting identifier bật:

```sql
-- SQL Server QUOTED_IDENTIFIER ON (mặc định): "Orders" = identifier
-- QUOTED_IDENTIFIER OFF: "Orders" = chuỗi — đừng dựa; proc có indexed view yêu cầu ON

-- PostgreSQL: "Orders" luôn identifier
```

Không có string interpolation. Nối: `+` (SQL Server), `||` (PG; SQL Server **2022+**), `CONCAT` — [operators.md](operators.md).

Newline **thật** trong literal (xuống dòng trong file SQL) hợp lệ cả hai — khác `'\n'` hai ký tự trên PG 19 `'…'` thường.

### 3.2 Prefix `N` (SQL Server)

```sql
SELECT 'tiếng Việt';                       -- varchar theo collation/code page — có thể mất ký tự
SELECT N'tiếng Việt';                      -- nvarchar (Unicode)
```

**Ghi chú:** Thiếu `N` trên literal Unicode → convert theo database collation; ký tự không có trong code page thành `?` **im lặng**. So sánh `nvarchar` cột với `varchar` literal: convert phía literal, có thể không dùng index / sai kết quả.

PostgreSQL UTF-8: `'tiếng Việt'` đã Unicode — **không** cần `N`. Prefix `N` trên PG không phải national character T-SQL (một số parser bỏ qua / lỗi).

`UNISTR(N'…')` nhận **nvarchar** chứa escape — thiếu `N` trên đối số = cùng bẫy code page trước khi unescape.

### 3.3 Backslash & `E'…'` (PostgreSQL)

PG 19: `standard_conforming_strings` **luôn on**. Trong `'…'` thường, `\` là ký tự thường, **không** escape.

```sql
-- PostgreSQL 19
SELECT '\';                                -- OK, một backslash
SELECT '\n';                               -- hai ký tự \ và n — không phải newline
SELECT E'\n';                              -- newline (escape-string)
SELECT E'O\'Brien';                        -- O'Brien — chỉ trong E'…'
SELECT E'\\';                              -- một backslash
SELECT E'\x41';                            -- hex byte trong escape-string (encoding)
```

Dump cũ `SET standard_conforming_strings = off` **không restore sạch** lên PG 19. `escape_string_warning` đã **gỡ** — script set biến này lỗi — [dialects.md](dialects.md) §10.3.

SQL Server: `\` **không** escape trong `'…'`. Newline = ký tự thật trong literal hoặc `CHAR(13)+CHAR(10)` / `NCHAR`.

```sql
-- SQL Server
SELECT 'line1' + CHAR(10) + 'line2';
SELECT N'c:\temp\file';                    -- backslash literal
```

**Ghi chú:** Path Windows `'C:\new'` trên PG 18 với `standard_conforming_strings=off` có thể nuốt `\n` thành newline. 19: luôn hai ký tự `\` + `n` trong `'…'` thường — **đúng** cho path, **sai** nếu script cũ dựa escape. Sửa: `E'…'` hoặc dollar-quote + newline thật.

Hai session — cùng file dump:

```text
T1 (PG 18, strings off): SELECT 'a\nb';    -- a, newline, b
T2 (PG 19):              SELECT 'a\nb';    -- a, \, n, b
                         SELECT E'a\nb';  -- a, newline, b
```

---

## 4. Unicode & escape

```sql
-- SQL Server 2025: UNISTR — \hhhh hoặc \\ + code point (docs: dấu \ + hex)
SELECT UNISTR(N'\\0041\\0042');            -- N'AB' — kiểm tra escape doubling trong chuỗi T-SQL
SELECT NCHAR(0x0041);                      -- N'A'
SELECT NCHAR(0x1F600);                     -- emoji; cột nvarchar cần collation SC để lưu đúng 1 “ký tự”

-- PostgreSQL: Unicode escape string U&'…'
SELECT U&'\0041\0042';                     -- 'AB'
SELECT U&'\+01F600';                       -- emoji (cú pháp \+hhhhhh cho > BMP)
SELECT U&'!0041' UESCAPE '!';              -- đổi escape character
```

**Ghi chú:**

- `UNISTR` là **2025**. Bản cũ: `NCHAR` / dán Unicode vào `N'…'`.
- Surrogate: `NCHAR` một unit 16-bit không đủ emoji nếu bạn tính `LEN` trên collation không SC — [typesystem.md](typesystem.md).
- `U&` chỉ PostgreSQL. Đừng nhầm với `U&` XML.
- Trong JSON literal, `\u0041` là escape JSON, không phải SQL `UNISTR` — parse hai lớp.
- `UNISTR` xử lý chuỗi **đã** là nvarchar. Escape `\\0041` trong T-SQL: mỗi `\` nhân đôi vì `\` không phải escape SQL Server — docs Learn: pattern `UNISTR(N'\xxxx')` vs doubling trong chuỗi nguồn. Test một code point trước khi copy bảng mapping.
- `E'\u0041'` **không** phải Unicode escape PG (`U&` mới là `\0041`). `E'\x41'` là byte hex Latin-1/UTF-8 tùy encoding.

Không có `UNISTR` trên PostgreSQL. Port: `U&'\0041'` hoặc `chr(65)` / `E'\u0041'` **sai** (u không phải escape POSIX trong E-string chuẩn).

---

## 5. Binary / bit / BASE64

```sql
-- SQL Server
SELECT 0xDEADBEEF;                         -- varbinary(4)
SELECT 0x;                                 -- empty
SELECT CONVERT(varbinary(4), 255);         -- không phải 0xFF luôn (endian / width)

-- PostgreSQL
SELECT '\xDEADBEEF'::bytea;
SELECT decode('DEADBEEF', 'hex');
SELECT B'1010';                            -- bit(4)
SELECT B'1010'::int;                       -- 10
```

PostgreSQL `bytea` output mặc định hex (`\x…`) từ lâu. Literal escape kiểu `E'\\001'` octal vẫn parse nhưng khó đọc — ưu tiên `\x`.

SQL Server không có bit-string `B'1010'`. `bit` T-SQL là 0/1/NULL, literal thường `0`/`1`/`CAST(1 AS bit)` — [typesystem.md](typesystem.md).

### BASE64 — không phải token literal

Không có `B64'…'` / `BASE64 '…'` trong SQL lõi. Base64 là **hàm** trên chuỗi/binary.

```sql
-- SQL Server 2025
SELECT BASE64_ENCODE(@blob);               -- binary → text
SELECT BASE64_DECODE(N'SGVsbG8=');         -- text → binary
-- Đừng viết BASE64 'SGVsbG8=' như typed literal

-- PostgreSQL
SELECT encode('\x48656c6c6f'::bytea, 'base64');
SELECT decode('SGVsbG8=', 'base64');
-- PG 19: encode(…, 'base64url') / 'base32hex' — alphabet khác, padding khác
```

**Ghi chú:**

- Input `BASE64_DECODE` / `decode` là **chuỗi** `'SGVsbG8='`, không `0x`.
- `base64url` (PG 19) ≠ `base64` (ký tự `+` `/` vs `-` `_`). Pipeline JWT vs MIME — chọn format tường minh.
- JSON chứa base64 vẫn là chuỗi JSON; `CAST AS json` rồi lấy key ≠ `decode` nhầm lớp.
- Vector/embedding API đôi khi gửi base64 float — **không** phải `vector` literal; decode → `CAST` kiểu `vector(n)` nếu engine cho (đo, đừng bịa).

---

## 6. Ngày giờ

### 6.1 Typed literal vs chuỗi

Chuỗi rồi cast — **đừng** dựa locale. PostgreSQL có typed literal chuẩn; SQL Server thiên về `CAST`/`CONVERT` + style, hoặc ODBC `{d '…'}`.

```sql
-- Cả hai (chuỗi ISO rồi cast)
SELECT CAST('2026-09-13' AS date);

-- PostgreSQL typed literal (khuyến nghị)
SELECT DATE '2026-09-13';
SELECT TIMESTAMP '2026-09-13 00:00:00';
SELECT TIMESTAMPTZ '2026-09-13 00:00:00+07';
SELECT TIME '13:45:00';

-- SQL Server
SELECT CAST('2026-09-13' AS date);                    -- date: ISO an toàn
SELECT CONVERT(datetime2(0), '2026-09-13 00:00:00', 120);
SELECT DATETIMEFROMPARTS(2026, 9, 13, 0, 0, 0, 0);
SELECT DATEFROMPARTS(2026, 9, 13);
SELECT CURRENT_DATE;                                  -- 2025, hàm — không phải literal ngày
```

`TIMESTAMP '…'` trên SQL Server **không** phải typed literal PG — `timestamp` T-SQL là `rowversion`. Viết `CAST(… AS datetime2)`.

`CURRENT_DATE` là hàm (SS **2025**, PG lõi), không literal. Gắn kiểu `date` — [typesystem.md](typesystem.md) §4.4.

### 6.2 `DATEFORMAT` / language

Bẫy SQL Server: literal `datetime`/`smalldatetime` phụ thuộc `DATEFORMAT` và language session.

```sql
-- SQL Server — hai session
SET DATEFORMAT mdy;
SELECT CAST('2026-09-13' AS datetime);     -- Sep 13 (mdy: 09=month, 13=day — OK ISO-like)

SET DATEFORMAT dmy;
SELECT CAST('2026-13-09' AS datetime);     -- lỗi hoặc đảo

SET LANGUAGE N'British';
SELECT CAST('13/09/2026' AS datetime);     -- 13 Sep
SET LANGUAGE N'us_english';
SELECT CAST('13/09/2026' AS datetime);     -- lỗi: 13 không phải tháng
```

**Ghi chú:** Kiểu `date` / `datetime2` nhận `yyyy-mm-dd` ổn định hơn `datetime` legacy. Vẫn dùng `CONVERT(…, 23)` (`yyyy-mm-dd`) hoặc `DATEFROMPARTS` trong code. App: parameter `date`/`datetime2`, không nối chuỗi ngày.

PostgreSQL `DateStyle` ảnh hưởng **output** và một số input không ISO. Input `DATE '2026-09-13'` luôn ISO. `TO_DATE('13/09/2026', 'DD/MM/YYYY')` tường minh.

`SET LANGUAGE` SQL Server còn đổi **tên tháng** trong một số convert và message lỗi — không đổi identifier folding.

### 6.3 `interval` (PostgreSQL)

```sql
SELECT INTERVAL '2 days 3 hours';
SELECT INTERVAL '1-2' YEAR TO MONTH;       -- 1 năm 2 tháng
SELECT DATE '2026-09-13' + INTERVAL '1 day';
SELECT TIMESTAMP '2026-09-13 00:00' + INTERVAL '3 hours';
```

SQL Server không có literal interval. `DATEADD(day, 2, @d)` / `DATEDIFF`. Không viết `INTERVAL` trong T-SQL rồi mong parse. `DATEADD` **2025** nhận `bigint` cho `number` — literal `86400` vẫn `int` nếu vừa; nhân `CAST(… AS bigint)` khi khoảng lớn — [typesystem.md](typesystem.md).

`FOR PORTION OF … FROM DATE '…' TO DATE '…'` dùng **typed date literal** (hằng, không column ref) — [dml.md](dml.md), [keywords.md](keywords.md). Bound `now()` được; literal sai format = lỗi statement.

---

## 7. Boolean, NULL

```sql
NULL                    -- không có kiểu; lấy từ cột / CAST / UNION
```

```sql
-- PostgreSQL
SELECT TRUE, FALSE;                        -- boolean literal
SELECT NULL::boolean;                      -- truth value UNKNOWN
SELECT TRUE IS UNKNOWN;                    -- false

-- SQL Server: không có TRUE / FALSE / UNKNOWN literal trong T-SQL
DECLARE @b bit = 1;
-- WHERE TRUE;                             -- lỗi
-- IF (TRUE)                               -- lỗi
```

`NULL` trong `UNION` / `VALUES` cần neo kiểu:

```sql
-- PostgreSQL: lỗi hoặc text tùy phiên bản/ngữ cảnh
SELECT NULL
UNION ALL
SELECT 1;                                  -- thường OK (neo int)

-- VALUES (NULL) một mình — unknown
INSERT INTO t (id, note) VALUES (1, NULL); -- note lấy kiểu cột
```

SQL Server `NULL` trong `SELECT NULL AS x INTO` → kiểu `int` (quy ước) — **bẫy** `SELECT NULL` + `INTO` rồi insert chuỗi.

JSON `null` trong text `'{"a":null}'` là JSON null, không phải SQL `NULL` cho đến khi extract. `JSON_VALUE` miss path (lax) → SQL `NULL`.

---

## 8. Array, row, JSON

```sql
-- PostgreSQL
SELECT ARRAY[1, 2, 3];
SELECT '{1,2,3}'::int[];                   -- literal text array — escape phức tạp hơn ARRAY[]
SELECT ARRAY['a', 'b'];
SELECT ROW(1, 'a');
SELECT (1, 'a')::address;                  -- composite
SELECT '{"a":1}'::jsonb;
SELECT '{"a":1}'::json;
```

Array text `'{a,b}'` vs `ARRAY['a','b']`: chuỗi có dấu phẩy / ngoặc phải escape. Ưu tiên constructor `ARRAY[…]`.

SQL Server 2025: JSON **không** có literal typed riêng — chuỗi rồi `CAST(… AS json)` hoặc constructor. Kiểu `json` native on-prem **PREVIEW** — [typesystem.md](typesystem.md).

```sql
SELECT CAST(N'{"a":1}' AS json);
SELECT JSON_OBJECT('a': 1);
SELECT JSON_ARRAY(1, 2, 3);
```

### `json_array()` rỗng — PG 19 breaking

```sql
-- PostgreSQL: hàm json_array() (SQL/JSON)
SELECT json_array();                       -- 19: [] 
-- Trước 19, 0 phần tử → NULL (một số ngữ cảnh / 0 hàng aggregate constructor)
```

Khi constructor/aggregate **0 hàng**:

```text
T1 (PG ≤18): SELECT json_array(v) FROM t WHERE false;   -- thường NULL
T2 (PG 19):  cùng câu                                   -- []
```

Client `if result is None` coi “không có mảng” **vỡ**. `[]` là JSON array rỗng hợp lệ. `json_agg` / `jsonb_agg` 0 hàng vẫn `NULL` (aggregate SQL) — **đừng** nhầm `json_array()` với `json_agg`.

SQL Server `JSON_ARRAY(1,2)` constructor list; `JSON_ARRAYAGG` aggregate — 0 hàng: đối chiếu Learn, thường `NULL` như aggregate. Không copy breaking PG sang T-SQL.

**Ghi chú:** `JSON_OBJECT('a': 1)` là hàm, không phải literal JSON. Key trùng / khoảng trắng: phụ thuộc kiểu `json` vs `jsonb` vs SQL Server `json` — [json.md](json.md). Không có array constructor T-SQL kiểu `ARRAY[]`. Vector `'[1,2,3]'` trông giống JSON array literal — cast `vector` ≠ `json`.

`SELECT ARRAY[]` PG lỗi thiếu kiểu — `ARRAY[]::int[]`. `JSON_ARRAY()` không đối số: SS list rỗng vs PG `json_array()` — đo, neo `CAST`.

---

## 9. Dollar-quoting (PostgreSQL)

Không cần nhân đôi nháy. Tag `$body$` / `$$` phải khớp; tag không alphanumeric tùy ý (tránh `$tag$` lồng nhầm).

```sql
SELECT $$O'Brien$$;
SELECT $body$
  IF NEW.id IS NULL THEN RAISE EXCEPTION 'no';
  END IF;
$body$;

CREATE FUNCTION f() RETURNS void
LANGUAGE plpgsql AS $fn$
BEGIN
    RAISE NOTICE '%', 'O''Brien';          -- vẫn được; dollar-quote cả thân thì khỏi escape
END;
$fn$;
```

SQL Server: không có dollar-quote. Thân proc T-SQL nhân đôi nháy, hoặc dynamic `CONCAT`. Chuỗi chứa `'` trong `sp_executesql` dễ lệch — dùng parameter.

Dump PG 19: dollar-quote **không** chịu `standard_conforming_strings` (không dùng `\` escape trong `$$`). Restore sạch hơn `E'…'` rải. Body hàm có `\'` cũ trong `'…'` thường: 19 giữ backslash literal — logic PL đổi.

---

## 10. Typed literal, unknown, parameter

PostgreSQL `'foo'` có kiểu **unknown** cho đến insert / operator / `CAST`. Nguồn lỗi `inconsistent types deduced for parameter` / `could not determine data type`.

```sql
PREPARE p AS SELECT $1;                    -- lỗi: không suy ra kiểu
PREPARE p(text) AS SELECT $1;

SELECT COALESCE(NULL, NULL);               -- lỗi: không xác định kiểu
SELECT COALESCE(NULL::int, NULL);

SELECT ARRAY[];                            -- lỗi; cần ARRAY[]::int[] hoặc ARRAY[1]
```

SQL Server parameter / `sp_executesql` **phải** khai báo kiểu. String literal không `N` convert theo collation DB.

```sql
-- SQL Server
EXEC sys.sp_executesql
    N'SELECT * FROM dbo.Orders WHERE Note = @n',
    N'@n nvarchar(200)',
    @n = N'tiếng Việt';                    -- thiếu N trên khai báo/gán → mất chữ
```

Client:

| | SQL Server | PostgreSQL |
|---|---|---|
| Positional | `@p1` trong `sp_executesql`; ADO `@name` | `$1`, `$2` libpq |
| Typed bind | SqlDbType / TDS | OID type (`jsonb` ≠ `json` ≠ `text`) |

Bind `json` thành `text` rồi so `jsonb` → không dùng GIN. Bind ngày thành chuỗi → lại `DATEFORMAT`. Bind `vector` thành string JSON array: SS client thấy array — [typesystem.md](typesystem.md). TDS **8** không đổi cú pháp literal; handshake TLS — [dialects.md](dialects.md).

`UNISTR` trên parameter: `UNISTR(@s)` — `@s` đã `nvarchar`. Đừng `UNISTR('…')` thiếu `N`.

---

## 11. ODBC escape (SQL Server)

```sql
SELECT {d '2026-09-13'};
SELECT {ts '2026-09-13 00:00:00'};
SELECT {t '13:45:00'};
SELECT {fn CONCAT('a', 'b')};
```

Driver/SSMS dịch escape thành T-SQL. PostgreSQL **không** dùng `{d '…'}` trong SQL lõi (một số ODBC driver dịch phía client). Code portable: typed `DATE '…'` / `CAST`.

sqlcmd/bcp 2025 + TDS 8: escape ODBC vẫn là *client*. File chạy `psql` chứa `{d '…'}` = syntax error.

---

## 12. Dump PG 19 — `standard_conforming_strings`

Incompatibility **cứng** — WHY nằm ở literal, không ở optimizer.

| Thay đổi | Ảnh hưởng restore |
|---|---|
| `standard_conforming_strings` luôn **on** | Dump 18 có `SET … = off` + `'…\n…'` **không** load sạch / đổi nghĩa `\` |
| `escape_string_warning` **gỡ** | Dòng `SET escape_string_warning` trong script **lỗi** |
| Client dump **19+** | `pg_dump` cũ phát `off` + escape kiểu cũ |

```sql
-- Script phải sửa trước restore 19
-- SET standard_conforming_strings = off;   -- fail / không còn
-- SET escape_string_warning = on;          -- fail: biến gỡ

-- Newline / tab / quote trong chuỗi:
SELECT E'line1\nline2';
SELECT $txt$line1
line2$txt$;
```

**Ghi chú:** Identifier CR/LF / `MULE_INTERNAL` cũng chặn `pg_upgrade` nhưng không phải literal — [dialects.md](dialects.md) §3.5. COPY text với `\` escape là *format COPY*, khác SQL literal — đọc `COPY` docs; PG 19 `ON_ERROR SET_NULL` không đổi luật `'…'` SQL.

Checklist: dump bằng binary 19; grep `escape_string_warning` và `standard_conforming_strings = off`; test restore lab với chuỗi path Windows và regex `'\\d+'`.

---

## 13. Hai session — ví dụ làm việc

### 13.1 `DATEFORMAT` đảo ngày

```text
T1: SET DATEFORMAT mdy; SELECT CAST('01/02/03' AS datetime);  -- 2003-01-02 (us)
T2: SET DATEFORMAT dmy; SELECT CAST('01/02/03' AS datetime);  -- 2003-02-01 (British-ish)
-- Cùng literal, hai ngày. Parameter date typed: không đảo.
```

### 13.2 Thiếu `N` vs UTF-8 PG

```text
T1 (SS, collation legacy): INSERT dbo.T (Note) VALUES ('tiếng');  -- ???? im lặng
T2 (PG UTF-8):             INSERT INTO t (note) VALUES ('tiếng'); -- đủ dấu
```

### 13.3 E-string vs conforming

Đã §3.3. Thêm regex:

```text
T1 (18, off): WHERE x ~ '\d+'     -- trong '…' \d có thể escape lệch
T2 (19):      WHERE x ~ '\d+'     -- POSIX: \d trong regex là lớp chữ số nếu pattern tới ~ đúng
              WHERE x ~ E'\\d+'   -- một \ tới POSIX
-- Review: pattern regex là literal SQL trước, POSIX sau — [operators.md](operators.md)
```

### 13.4 `json_array()` API client

```text
T1 (18):  empty constructor → NULL → JSON null / SQL NULL phía driver
T2 (19):  [] → array rỗng, không IS NULL
-- OpenAPI “nullable array” vs “empty array”
```

### 13.5 BASE64 nhầm hex

```text
T1: INSERT blob VALUES (0x48656c6c6f);           -- binary Hello
T2: INSERT blob VALUES ('SGVsbG8=');             -- nếu cột varbinary: convert thất bại / sai
    -- Đúng: BASE64_DECODE(N'SGVsbG8=') / decode('SGVsbG8=', 'base64')
```

---

## 14. Best practices & checklist

- Ngày: ISO `yyyy-mm-dd` + kiểu `date`/`datetime2`/`DATE '…'`; không `datetime` + language.
- Unicode SQL Server: `N'…'` mọi literal/parameter; `UNISTR` khi escape code point (2025).
- PG 19: đừng viết dump `standard_conforming_strings=off`; newline dùng `E'\n'` hoặc literal xuống dòng thật / dollar-quote. Gỡ `SET escape_string_warning`.
- Tiền: `numeric` literal `1.23`, không `1.23e0`.
- JSON: constructor / `CAST AS json(b)`; đừng nối chuỗi JSON bằng tay nếu có hàm. Client `json_array()` rỗng = `[]` trên 19.
- BASE64: hàm encode/decode, không token; PG 19 chọn `base64` vs `base64url`.
- Dynamic SQL: parameter cho giá trị; dollar-quote thân hàm PG.
- `NULL` trong `UNION`/`COALESCE`/`VALUES`: `CAST` tường minh.
- Hex: nhớ `0x` T-SQL = binary, không phải int; PG `\x` = `bytea`.
- Không digit separator; không `INTERVAL` trên T-SQL; không `{d}` trong `psql`.

---

## 15. Bẫy khi review

- `'A' = 'a'` “đúng trên SSMS” (CI) — literal không chứng minh collation PG.
- Thiếu `N` trên tiếng Việt / emoji.
- `'\\n'` mong newline trên PG 19 (không, trừ `E'…'`).
- `TIMESTAMP '…'` trong script “portable” — T-SQL đọc `timestamp` = rowversion.
- `{d '…'}` trong file chạy `psql`.
- `0x0A` dùng như số 10.
- `TRUE` trong stored proc T-SQL.
- `PREPARE` không kiểu; `COALESCE(NULL, NULL)`.
- `SET DATEFORMAT` trong proc + literal `'01/02/03'`.
- Dollar-tag `$tag$` xuất hiện trong thân chuỗi (đóng sớm).
- JSON `'{"a":1}'` gán cột `jsonb` qua parameter `text` không `::jsonb`.
- `SELECT 7/2` “chứng minh” float vì literal viết `7.0` ở chỗ khác.
- Dump 18 `standard_conforming_strings=off` restore 19.
- `SET escape_string_warning` trên 19.
- `UNISTR` thiếu doubling `\` / thiếu `N`.
- `BASE64 '…'` như typed literal (không tồn tại).
- `json_array()` 0 hàng: `IS NULL` sau nâng 19.
- `U&'\0041'` copy sang T-SQL; `UNISTR` copy sang PG.
- `E'\u0041'` tưởng Unicode PG (phải `U&`).
- Vector `'[…]'` gán cột `json` nhầm.

---

## 16. Version gates

| Mục | SQL Server | PostgreSQL |
|---|---|---|
| Prefix `N` | lõi | không cần (UTF-8) |
| `UNISTR` | **2025** | `U&'…'` lâu |
| `E'…'` escape-string | — | lõi; **19**: `standard_conforming_strings` luôn on |
| `standard_conforming_strings=off` | — | **19: không restore** |
| `escape_string_warning` | — | **19: gỡ** |
| `JSON_OBJECT` / `JSON_ARRAY` | 2022+ / **2025** agg | `json(b)_build_*` lâu |
| `CAST(… AS json)` native | **2025 PREVIEW** on-prem | `::json` / `::jsonb` lâu |
| `json_array()` 0 hàng → `[]` | — | **19 breaking** |
| `BASE64_ENCODE` / `BASE64_DECODE` | **2025** | `encode`/`decode`; **19** `base64url`/`base32hex` |
| Dollar-quoting | — | lõi |
| `DATE '…'` typed | ODBC `{d}` / `CAST` | lõi |
| `INTERVAL '…'` | — | lõi |
| `CURRENT_DATE` (hàm, không literal) | **2025** | lõi |
| `0x` binary literal | lõi | dùng `bytea` `\x` |
| `\|\|` nối (không phải literal) | **2022+** | lõi |

Comment / batch / `GO`: [dialects.md](dialects.md). Keyword `TRUE`/`USER`: [keywords.md](keywords.md). Kiểu sau neo: [typesystem.md](typesystem.md).

---

## Phụ lục A. `UNISTR` — doubling `\` trong T-SQL

`UNISTR` đọc escape **trong chuỗi đã parse**. T-SQL `'…'` **không** coi `\` là escape, nên một backslash trong nguồn là một ký tự tới hàm.

```sql
-- SQL Server 2025 — đo trên instance; docs Learn: \hhhh
SELECT UNISTR(N'\0041');                 -- thường N'A' nếu parser đưa \0041 vào hàm
SELECT UNISTR(N'\\0041');                -- nếu nguồn đã nhân đôi: một \ tới UNISTR → \0041
SELECT UNISTR(N'\+01F600');              -- > BMP: đối chiếu Learn (hình thức \+ / surrogate)
```

Hai lớp:

1. Parser T-SQL: `N'\\' ` → một `\`.
2. `UNISTR`: `\0041` → U+0041.

Dynamic SQL: `N'UNISTR(N''\0041'')'` — nháy nhân đôi **và** `\` — dễ lệch. Parameter `nvarchar` chứa sẵn `\0041` rồi `UNISTR(@p)` sạch hơn.

PostgreSQL tương đương: `U&'\0041'` (parser SQL, một lớp) hoặc `chr(65)`. Không `UNISTR`. `E'\u0041'` **không** phải Unicode escape chuẩn PG.

**Ghi chú:** Collation không SC: emoji từ `UNISTR` lưu hai unit UTF-16 — `LEN` = 2. Cột `varchar` + `UNISTR` → code page nuốt trước khi unescape nếu thiếu `N`.

---

## Phụ lục B. COPY / bcp vs SQL literal

`COPY` (PG) và `bcp`/`BULK INSERT` (SS) có **format file**, không dùng luật `'…'` SQL.

| | SQL `'…'` | COPY text/CSV (PG) | bcp / BULK |
|---|---|---|---|
| `\` | PG 19: ký tự thường trong `'…'` | Escape COPY riêng (`\N` = NULL) | Tùy format |
| `'` | Nhân đôi | CSV quote | Field terminator |
| `standard_conforming_strings` | Luôn on 19 | Không áp | — |
| `ON_ERROR SET_NULL` | — | **19** input invalid → NULL | SS có maxerrors / fire triggers |

```sql
-- PostgreSQL 19: COPY FROM … ON_ERROR SET_NULL  — nuốt dữ liệu bẩn
-- Không dùng load tài chính. WHERE trên COPY cấm system column (xmin, ctid).
```

Dump **SQL** (`pg_dump` inserts / COPY statements trong `.sql`) vẫn chứa literal SQL + lệnh `SET`. Restore 19 gãy ở `SET standard_conforming_strings = off` **trước** khi đụng COPY data.

`COPY TO` JSON / `FORCE_ARRAY` **19** ≠ `json_array()` SQL. File JSON array vs constructor 0 hàng `[]`.

---

## Phụ lục C. Regex pattern như literal

Pattern tới `~` / `REGEXP_LIKE` đi qua **SQL literal trước**.

```sql
-- PostgreSQL 19
WHERE phone ~ '\d{3}';           -- '\' + 'd{3}' tới POSIX — \d thường vẫn là lớp chữ số POSIX
WHERE phone ~ E'\\d{3}';         -- một '\' tới POSIX
WHERE phone ~ $$\\d{3}$$;        -- dollar: hai ký tự \ d hay một \ ? — $$ \\d $$ = \ + \ + d

-- SQL Server 2025
WHERE REGEXP_LIKE(phone, N'\d{3}');
WHERE REGEXP_LIKE(phone, N'\\d{3}');   -- tùy engine regex: \\ là \ literal hay lỗi
```

Hai session — dump 18 `off` vs 19:

```text
T1 (18, off): pattern trong dump 'a\nb' đã unescape lúc restore
T2 (19):      cùng dump không SET off → '\' giữ; regex/path Windows đổi nghĩa
```

Test một hàng thật, không review pattern “trông POSIX”. Chi tiết toán tử: [operators.md](operators.md).

---

## Phụ lục D. Mix literal và parameter — estimate

```sql
-- SQL Server: literal 1 vs @id int
SELECT * FROM dbo.Orders WHERE Id = 1;          -- density 1
SELECT * FROM dbo.Orders WHERE Id = @id;        -- sniff / OPPO 2025 — [internal.md](internal.md)

-- PostgreSQL
SELECT * FROM orders WHERE id = 1;              -- custom / generic tùy prepare
SELECT * FROM orders WHERE id = $1;
```

Literal `IN (1,2,3)` khác `= ANY(@arr)`. PG `= ANY(ARRAY[1,2,3])` — `ARRAY[…]` constructor, phần tử là literal integer. `IN ('2026-09-13')` neo kiểu qua cột, không qua `DATEFORMAT` nếu cột `date` — vẫn đừng mix chuỗi ngày.

`NULL` literal vs parameter NULL: `WHERE k = NULL` luôn UNKNOWN; `WHERE k = @k` với `@k` NULL cùng bẫy. `IS NOT DISTINCT FROM @k` — [operators.md](operators.md).

---

## Phụ lục E. `json_array()` vs `JSON_ARRAY` vs `json_agg`

| Biểu thức | Engine | 0 phần tử / 0 hàng |
|---|---|---|
| `json_array()` constructor SQL/JSON | PG **19** | `[]` (trước: `NULL`) |
| `json_agg(x)` / `jsonb_agg` | PG | `NULL` (aggregate SQL) |
| `JSON_ARRAY(1,2)` list | SS 2022+ | list rỗng: đo Learn |
| `JSON_ARRAYAGG(x)` | SS **2025** (on-prem **PREVIEW**) | thường `NULL` như aggregate |
| `CAST('[]' AS json)` | SS **PREVIEW** / PG `::json` | array rỗng typed |

Client OpenAPI: `nullable: true` trên field array ≠ `[]`. Nâng PG 19: đổi contract. Không “sửa” bằng `COALESCE(json_array(), 'null'::json)` trừ khi nghiệp vụ muốn JSON null.

Hai session — API versioning:

```text
T1 (PG 18 app): empty json_array() → NULL → JSON null / omit field
T2 (PG 19 app): [] → field hiện array rỗng — client cũ `if (x == null)` bỏ qua validation `minItems`
```

`JSON_ARRAYAGG` SS **PREVIEW** on-prem 0 hàng: đừng copy `[]` từ PG 19 vào giả định T-SQL. Neo `COALESCE(JSON_ARRAYAGG(…), JSON_ARRAY())` chỉ khi đã đo hàm tồn tại và preview chấp nhận.
