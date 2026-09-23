# JSON

> **Baseline:** SQL Server **2025** (17.x) · PostgreSQL **19**.  
> JSON trong RDBMS là **tài liệu trong cột**, không phải document DB. Cột quan hệ + index rẻ hơn document khi query equality ổn định.

SQL Server 2025 thêm kiểu `json` binary (**on-prem 2025: PREVIEW** theo Learn; **GA Azure SQL / MI** policy 2025). PostgreSQL: `json` (text) vs **`jsonb`** (binary) — mặc định mới nên `jsonb`. Path, modify, unnest (`OPENJSON` vs `jsonb_to_recordset`), aggregate (`JSON_OBJECTAGG` **PREVIEW** on-prem / `json_array()` rỗng → `[]` ở **19**) lệch mạnh. Index: `CREATE JSON INDEX` **PREVIEW** vs GIN.

Kiểu & literal: [typesystem.md](typesystem.md), [literals.md](literals.md). Toán tử `@>` / `JSON_VALUE`: [operators.md](operators.md). Index JSON/vector: [indexes.md](indexes.md).

---

## Mục lục

- [1. Tổng quan \& triết lý](#1-tổng-quan--triết-lý)
- [2. On-prem PREVIEW vs Azure GA](#2-on-prem-preview-vs-azure-ga)
- [3. json vs jsonb vs nvarchar](#3-json-vs-jsonb-vs-nvarchar)
- [4. Tạo JSON](#4-tạo-json)
- [5. Đọc theo path](#5-đọc-theo-path)
- [6. Sửa document: JSON\_MODIFY vs json.modify](#6-sửa-document-json_modify-vs-jsonmodify)
- [7. Unnest: OPENJSON vs jsonb\_to\_recordset](#7-unnest-openjson-vs-jsonb_to_recordset)
- [8. Aggregate \& json\_array() \[\] breaking](#8-aggregate--json_array--breaking)
- [9. Index JSON](#9-index-json)
- [10. COPY TO JSON (PostgreSQL 19)](#10-copy-to-json-postgresql-19)
- [11. Validate](#11-validate)
- [12. Worked examples](#12-worked-examples)
  - [12.8 Bảng hàm JSON](#128-bảng-hàm-json-không-bịa)
  - [12.9 On-prem vs Azure](#129-on-prem-vs-azure--checklist-migrate-schema)
  - [12.10 GIN vs btree vs JSON INDEX](#1210-gin-vs-btree-vs-json-index--chọn)
- [13. Best practices \& checklist](#13-best-practices--checklist)
- [14. Bẫy khi review](#14-bẫy-khi-review)
- [15. Version gates](#15-version-gates)
- [Phụ lục A. JSON\_CONTAINS \& wildcard](#phụ-lục-a-json_contains--wildcard-preview-on-prem)
- [Phụ lục B. json\_array vs json\_agg vs COPY](#phụ-lục-b-json_array-vs-json_agg-vs-copy)
- [Phụ lục C. In-place modify](#phụ-lục-c-in-place-modify--khi-nào-rewrite)
- [Phụ lục D. Migrate nvarchar → json](#phụ-lục-d-migrate-nvarchar--json-on-prem)
- [Phụ lục E. COPY TO JSON](#phụ-lục-e-copy-to-json--quyền-và-format)
- [Phụ lục F. NULL semantics](#phụ-lục-f-null-semantics--sửa-document)
- [Phụ lục G. JSON\_ARRAYAGG](#phụ-lục-g-json_arrayagg--returning-json--môi-trường)
- [Phụ lục H. Path \$ vs ->](#phụ-lục-h-path--vs----lỗi-hay-gặp)
- [Phụ lục I. json\_array client](#phụ-lục-i-json_array--sửa-client)
- [Phụ lục J. Checklist JSON](#phụ-lục-j-checklist-json-why)

---

## 1. Tổng quan & triết lý

JSON cho schema linh hoạt (thuộc tính phụ, payload API, log). Key luôn query, join, FK → **cột**. Update một key trên document 10 MB = I/O lớn (rewrite hoặc binary patch tùy engine).

Hai dialect:

- SQL Server: historically `nvarchar` + `ISJSON` / `JSON_VALUE`. 2025: kiểu `json`, JSON index, `JSON_CONTAINS`, `JSON_OBJECTAGG`/`JSON_ARRAYAGG`, method `modify` — **nhiều mục PREVIEW trên on-prem**, trong khi Azure SQL / MI đã GA một phần.
- PostgreSQL: `jsonb` + GIN `@>` là surface chín. `json` text giữ formatting, chậm hơn. 19: `json_array()` rỗng → `[]` (breaking); `COPY TO` `FORMAT json`.

Đừng khóa schema prod on-prem vào kiểu `json` + JSON INDEX nếu chưa chấp nhận CU đổi API. Staging Azure “chạy rồi” **không** chứng minh on-prem GA.

---

## 2. On-prem PREVIEW vs Azure GA

Learn (policy 2025, đối chiếu CU): kiểu **json** GA trên Azure SQL Database / Azure SQL Managed Instance (update policy SQL Server 2025 hoặc Always-up-to-date). **On-prem SQL Server 2025: PREVIEW** (và SQL database in Fabric — docs hiện tại gắn preview). Hàm cũ (`JSON_VALUE`, `OPENJSON`, `FOR JSON`, `JSON_MODIFY`) vẫn chạy trên `nvarchar` **và** trên kiểu `json` — đó là đường GA lâu, không cần flag.

**PREVIEW on-prem (nhiều mục JSON 2025):**

| Surface | On-prem 2025 | Azure SQL / MI (policy 2025) |
|---|---|---|
| Kiểu `json` binary (~2 GB/row, UTF-8 nội bộ) | **PREVIEW** | **GA** |
| `CREATE JSON INDEX` | **PREVIEW** | Theo Learn — đừng giả on-prem = cloud |
| `JSON_CONTAINS` | **PREVIEW** | Đo từng môi trường |
| `JSON_OBJECTAGG` / `JSON_ARRAYAGG` (`RETURNING JSON`) | **PREVIEW** | GA Azure / Fabric DW (policy) |
| Method `json.modify` | **PREVIEW** (2025) | Đối chiếu Learn; `JSON_MODIFY` hàm = lâu |
| Wildcard path ANSI / `JSON_QUERY … WITH ARRAY WRAPPER` | **PREVIEW** | Đo |
| `JSON_VALUE` / `OPENJSON` / `FOR JSON` / `ISJSON` | GA (2016+) | GA |

Một số PREVIEW còn `ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON` (vector index, CES, fuzzy — **không** chỉ JSON). Bật flag “cho JSON INDEX” có thể kéo feature khác theo **database**. JSON INDEX / `json.modify`: đọc note Learn *currently in preview* trên on-prem — không bịa “chỉ cần compat 170”.

**Ghi chú:** Dùng chữ **on-prem**, không “boxed”. Feature flag lệch môi trường = bug CI: pipeline Azure dùng `JSON_OBJECTAGG RETURNING JSON`, on-prem lab fail hoặc preview.

---

## 3. json vs jsonb vs nvarchar

**Hình dung.** `json` PostgreSQL (và `nvarchar` + `ISJSON`) = **tờ giấy** nguyên văn: khoảng trắng, thứ tự key, key trùng đều còn — mỗi lần đọc phải parse lại.

`jsonb` (và kiểu `json` binary SQL Server 2025) = **đã bóc** thành cấu trúc: hết khoảng trắng, key trùng thì key sau thắng, so sánh theo giá trị không theo chuỗi. `{"b":1,"a":2}` và `{"a":2,"b":1}` bằng nhau trên `jsonb`, không bằng nhau nếu so text.

Cột luôn lọc `status = 'open'` → cột quan hệ hoặc expression index, đừng so cả tờ giấy. Cập nhật một key trên document 10 MB thường **viết lại cả giá trị**.

| | SQL Server 2025 | PostgreSQL |
|---|---|---|
| Native binary | `json` (UTF-8 nội bộ, ~2 GB/row) **PREVIEW** on-prem / **GA Azure** | **`jsonb`** |
| Text | `nvarchar`/`varchar` + `ISJSON` | `json` (giữ khoảng trắng, thứ tự key, key trùng) |
| Nên dùng cột mới | `json` khi chấp nhận preview (hoặc Azure GA); không thì `nvarchar` + computed | `jsonb` |

`jsonb` **không** giữ khoảng trắng, thứ tự key, key trùng (key sau thắng). `json` PG giữ nguyên — parse mỗi lần đọc. SQL Server `json` binary đã parse; expose/tương thích hàm JSON cũ.

Input kiểu `json` SS: object hoặc array (RFC; không scalar trần theo docs kiểu). Invalid → lỗi convert lúc ghi.

```sql
-- SQL Server
CREATE TABLE dbo.Doc (
    Id      int NOT NULL PRIMARY KEY CLUSTERED,   -- JSON INDEX đòi clustered PK
    Payload json NOT NULL                         -- PREVIEW on-prem
);

-- Cũ (GA, rollback dễ)
Payload nvarchar(max) NOT NULL
    CONSTRAINT CK_Doc_Payload CHECK (ISJSON(Payload) = 1)

-- PostgreSQL
CREATE TABLE doc (
    id      int PRIMARY KEY,
    payload jsonb NOT NULL
);
```

Ép kiểu: `SELECT CAST(N'{"a":1}' AS json)` (SS) / `'{"a":1}'::jsonb` (PG). Invalid → lỗi lúc convert, không lúc “đọc path” nếu đã binary.

**Ghi chú:** Duplicate key: `jsonb` gộp; `nvarchar`/`json` text giữ — `JSON_VALUE` phụ thuộc parse. Số JSON `1` vs `1.0` vs scientific: so sánh `jsonb` khác text. Đừng so JSON string equality để “đổi dữ liệu”. `CAST(col AS json)` migrate: lọc `ISJSON = 1` trước; hàng bẩn fail.

---

## 4. Tạo JSON

```sql
-- SQL Server: hàng → JSON
SELECT id, name
FROM dbo.Customers
FOR JSON PATH, ROOT('customers');

SELECT JSON_OBJECT('id': id, 'name': name);
SELECT JSON_ARRAY(1, 2, 3);
SELECT JSON_OBJECT('id': id, 'name': name RETURNING JSON);  -- kiểu json

-- PostgreSQL
SELECT json_build_object('id', id, 'name', name);
SELECT jsonb_build_object('id', id, 'name', name);
SELECT to_jsonb(t) FROM customers t;
SELECT json_object_agg(sku, qty) FROM items;   -- aggregate, mục 8
SELECT json_array(1, true);                    -- constructor SQL/JSON
```

`FOR JSON PATH` vs `AUTO`: PATH theo alias lồng (`user.name`); AUTO theo join. `WITHOUT_ARRAY_WRAPPER` một object. `INCLUDE_NULL_VALUES` (SS) vs PG mặc định bỏ/giữ tùy hàm (`json_build_object` giữ NULL).

PG 19: `COPY TO` output JSON (kể `FORCE_ARRAY`) — mục 10, không phải `FOR JSON`. `jsonpath` thêm hàm immutable (`lower` / `ltrim` / … — docs 19).

**Ghi chú:** `JSON_OBJECT('a': 1)` là **hàm**, không literal JSON trong T-SQL. Key động: cẩn thận injection nếu nối chuỗi; dùng hàm bind giá trị.

---

## 5. Đọc theo path

```sql
-- SQL Server
SELECT JSON_VALUE(doc, '$.user.name');            -- scalar; object → NULL (lax)
SELECT JSON_QUERY(doc, '$.user');                 -- object/array
SELECT JSON_VALUE(doc, '$.items[0].sku');
SELECT JSON_PATH_EXISTS(doc, '$.user.name');      -- 0/1
-- 2025 PREVIEW: wildcard mảng ANSI; JSON_QUERY … WITH ARRAY WRAPPER
SELECT JSON_CONTAINS(doc, 'fitness', '$.tags');   -- PREVIEW; dùng JSON INDEX

-- PostgreSQL
SELECT doc -> 'user' ->> 'name';                  -- -> jsonb, ->> text
SELECT doc #>> '{user,name}';
SELECT doc -> 'items' -> 0 ->> 'sku';
SELECT jsonb_path_query(doc, '$.items[*] ? (@.qty > 1)');
SELECT doc @> '{"user":{"id":1}}'::jsonb;         -- containment, GIN
SELECT jsonb_path_exists(doc, '$.user.name');
```

`JSON_VALUE` lax: path sai / kiểu sai → `NULL`. `strict`: lỗi. PG `->` không tồn tại key → `NULL`. `->>` luôn text (mất kiểu số).

SQL Server path **bắt buộc** `$`. PG `jsonpath` cũng `$` trong `jsonb_path_*`; toán tử `->` dùng key/index.

**Ghi chú:** `JSON_VALUE` ra object = `NULL` im lặng (dùng `JSON_QUERY`). So sánh `JSON_VALUE(…, '$.qty') = 1` = nvarchar vs int — convert; JSON INDEX / `JSON_CONTAINS` **không** implicit convert kiểu (số vs chuỗi `'11000'` không khớp).

---

## 6. Sửa document: JSON_MODIFY vs json.modify

```sql
-- SQL Server: JSON_MODIFY (nvarchar/json) — GA lâu
SELECT JSON_MODIFY(doc, '$.user.name', N'Ada');
SELECT JSON_MODIFY(doc, 'append $.tags', N'sql');
SELECT JSON_MODIFY(doc, '$.secret', NULL);        -- xóa key (NULL, lax)

UPDATE dbo.Doc
SET Payload = JSON_MODIFY(Payload, '$.user.name', @name)
WHERE Id = @id;
```

**PREVIEW on-prem:** method `modify` trên cột kiểu **`json`** — ưu tiên in-place khi đủ chỗ (chuỗi mới ≤ cũ; số cùng kiểu / trong range — Learn). Không gán lại cả document nếu patch nhỏ.

```sql
-- Learn: json data type — modify (PREVIEW, SQL Server 2025)
UPDATE dbo.Doc
SET Payload.modify('$.a', 14859)
WHERE Id = 1;

UPDATE dbo.Doc
SET Payload.modify('$.b', 'def')
WHERE Id = 1;
```

Cột `nvarchar`: **không** có `.modify` — dùng `JSON_MODIFY`. Azure: kiểu `json` GA nhưng method `modify` vẫn đọc note preview trên 2025 docs — đối chiếu Learn trước khi viết proc.

PostgreSQL jsonb:

```sql
SELECT jsonb_set(doc, '{user,name}', '"Ada"'::jsonb);
SELECT doc || '{"ok": true}'::jsonb;
SELECT doc - 'secret';
SELECT jsonb_insert(doc, '{tags,-1}', '"sql"'::jsonb, true);

UPDATE doc
SET payload = jsonb_set(payload, '{user,name}', to_jsonb(@name))
WHERE id = @id;
```

Cập nhật cột = gán document mới (trừ optimize binary/preview `modify`). Key sâu trên LOB lớn = rewrite. Tách cột nóng ra quan hệ nếu update thường xuyên.

`JSON_MODIFY` path `append` / `lax`/`strict`. Không merge sâu như `||` jsonb (jsonb `||` object = key-level, không recursive sâu trừ `jsonb_set`).

**Ghi chú:** `jsonb_set` tạo path thiếu tùy `create_missing`. Giá trị phải là jsonb (`'"Ada"'` có quotes JSON). Truyền text `Ada` không quote = invalid. `jsonb_set` với JSON `null` **không** xóa key (`-` mới xóa). `JSON_MODIFY(..., NULL)` trên SS **xóa** key (lax).

---

## 7. Unnest: OPENJSON vs jsonb_to_recordset

```sql
-- SQL Server
SELECT j.sku, j.qty
FROM dbo.Doc AS d
CROSS APPLY OPENJSON(d.Payload, '$.items')
WITH (
    sku nvarchar(32) '$.sku',
    qty int          '$.qty'
) AS j;

-- Không schema: key, value, type
SELECT * FROM OPENJSON(@json);

-- PostgreSQL
SELECT x.sku, x.qty
FROM doc
CROSS JOIN LATERAL jsonb_to_recordset(payload -> 'items')
    AS x(sku text, qty int);

SELECT e.*
FROM doc,
LATERAL jsonb_array_elements(payload -> 'items') AS e;

SELECT * FROM json_to_recordset(payload) AS x(sku text, qty int);  -- json text
```

`OPENJSON` + `WITH` ép kiểu SQL; sai kiểu → `NULL`/lỗi tùy convert. `jsonb_to_recordset` thiếu key → NULL cột. Fan-out: một document N phần tử = N hàng — join tiếp dễ nổ cardinality.

`OPENJSON` mặc định trên `$` nếu bỏ path. Mảng object vs mảng scalar: schema khác (`'$'` vs không key).

PG: `jsonb_each` / `jsonb_each_text` cặp key-value object. `jsonb_populate_record` đổ vào composite/table row type.

**Ghi chú:** Unnest trong view + filter ngoài = parse mọi hàng. Đẩy predicate vào document (`@>` / `JSON_CONTAINS`) trước rồi unnest ít hàng. Materialize (`INTO temp` / CTE) khi join nhiều lần cùng mảng.

---

## 8. Aggregate & json_array() [] breaking

```sql
-- SQL Server 2025 — JSON_OBJECTAGG / JSON_ARRAYAGG: PREVIEW trên on-prem;
-- GA Azure SQL / MI (policy 2025) / Fabric DW
SELECT customer_id, JSON_ARRAYAGG(id ORDER BY id)
FROM dbo.Orders
GROUP BY customer_id;

SELECT JSON_OBJECTAGG(sku: qty) FROM dbo.Items;
SELECT JSON_OBJECTAGG(sku: qty RETURNING JSON);     -- kiểu json
SELECT JSON_ARRAYAGG(1 RETURNING JSON);

-- GROUPING SETS được hỗ trợ trên aggregate JSON (Learn)
```

PostgreSQL:

```sql
SELECT customer_id, json_agg(id ORDER BY id)
FROM orders
GROUP BY customer_id;

SELECT jsonb_object_agg(sku, qty) FROM items;
SELECT jsonb_agg(t) FROM items t;
```

### 8.1 PG 19 breaking: `json_array()` 0 hàng → `[]`

Constructor SQL/JSON `json_array(query)`: subquery **0 hàng** trước 19 trả `NULL` (rewrite nhầm thành `json_arrayagg` trên empty set). **19** theo chuẩn: **`[]`**.

```sql
-- PostgreSQL 19
SELECT json_array(SELECT x FROM generate_series(1, 0) AS t(x));
-- []  (trước 19: NULL)
```

App `IS NULL` khi “không phần tử” phải sửa. Giữ NULL cũ: `NULLIF(json_array(SELECT …), '[]'::json)` — chỉ khi thật sự cần tương thích.

`json_agg` / `json_arrayagg`: 0 hàng trong `GROUP BY` không tạo nhóm; scalar subquery `SELECT json_agg(x) FROM empty` → **`NULL`** (khác `json_array()`). Đừng nhầm hai hàm. Muốn `[]`: `COALESCE(json_agg(…), '[]'::json)`.

**Ghi chú:** Key trùng trong `JSON_OBJECTAGG` / `jsonb_object_agg`: key sau thắng (không lỗi). `ORDER BY` trong `JSON_ARRAYAGG` / `json_agg` để array ổn định. `RETURNING JSON` SS = kiểu `json` (preview on-prem).

---

## 9. Index JSON

```sql
-- SQL Server 2025 PREVIEW on-prem
CREATE JSON INDEX jix ON dbo.Doc (Payload);                 -- recursive $
CREATE JSON INDEX jix2 ON dbo.Doc (Payload)
    FOR ('$.status', '$.user.id');                         -- không overlap

-- Computed + btree (cách cũ, vẫn valid trên nvarchar) — GA
ALTER TABLE dbo.Doc
    ADD Status AS (JSON_VALUE(Payload, '$.status')) PERSISTED;
CREATE INDEX ix_doc_status ON dbo.Doc (Status);

-- PostgreSQL
CREATE INDEX ON doc USING gin (payload);                    -- jsonb_ops, tồn tại key
CREATE INDEX ON doc USING gin (payload jsonb_path_ops);     -- chỉ @>
CREATE INDEX ON doc ((payload->>'status'));                 -- btree equality
```

JSON INDEX: clustered PK bắt buộc; không indexed view / memory-optimized / computed json. Path `FOR` recursive — `$.user` gồm `$.user.id`; thêm cả hai = lỗi. Phục vụ `JSON_VALUE`, `JSON_PATH_EXISTS`, `JSON_CONTAINS`.

`jsonb_path_ops` nhỏ, **không** hỗ trợ tồn tại key/`?` đầy đủ như `jsonb_ops`. Expression btree khi một key equality nóng.

Vector trong JSON array ≠ kiểu `vector` — [indexes.md](indexes.md) §9, [typesystem.md](typesystem.md).

**Ghi chú:** GIN update đắt trên document lớn. Index mọi path `$` = phình. Chọn path query thật. Heap-only không JSON INDEX.

---

## 10. COPY TO JSON (PostgreSQL 19)

`COPY TO` thêm `FORMAT json` (**chỉ TO**, không `COPY FROM` json). Mặc định **NDJSON**: một object JSON mỗi hàng, newline. `FORCE_ARRAY`: một array `[…]`, hàng cách bằng dấu phẩy.

```sql
COPY (SELECT id, payload FROM doc) TO STDOUT WITH (FORMAT json);

COPY (SELECT * FROM (VALUES (1), (2)) AS v(id))
    TO STDOUT WITH (FORMAT json, FORCE_ARRAY);

COPY doc TO '/tmp/doc.json' WITH (FORMAT json, FORCE_ARRAY);
```

`FORCE_ARRAY` chỉ hợp lệ `COPY TO` + `json`. Không kết hợp option CSV (`HEADER`, `DELIMITER`, `QUOTE`, `NULL`, `FORCE_QUOTE`, …) với format json — docs `COPY`.

Server-side `COPY … TO 'filename'` cần quyền file trên server (`pg_write_server_files` / superuser). Client: `\copy` — file máy local.

Không phải `FOR JSON PATH`. Không `json_agg` (không GROUP BY, streaming). SQL Server: `FOR JSON` / BCP / `OPENROWSET` — **không** `COPY FORMAT json`.

PG 19 khác trên `COPY FROM` (không JSON): skip nhiều header; `ON_ERROR SET_NULL`; SIMD text/CSV; `COPY FROM … WHERE` **cấm** system column (`xmin`, `ctid`). `ON_ERROR SET_NULL` nuốt dữ liệu bẩn — không load tài chính. `COPY TO` partitioned table trực tiếp (19).

**Ghi chú:** NDJSON ≠ một document JSON hợp lệ (thiếu `[`). Client `json.load` cả file fail trừ `FORCE_ARRAY`. Array lớn = một giá trị — memory client, khác stream NDJSON.

---

## 11. Validate

```sql
-- SQL Server
WHERE ISJSON(txt) = 1                          -- nvarchar
WHERE ISJSON(txt, OBJECT) = 1                  -- 2022+: object/array
-- cột json: INSERT invalid → lỗi convert
CHECK (JSON_PATH_EXISTS(Payload, '$.basket') = 1)

-- PostgreSQL
SELECT '{"a":1}'::jsonb;                       -- lỗi nếu invalid
SELECT payload IS JSON OBJECT;                 -- SQL/JSON IS JSON
-- PG 19: IS JSON trên domain overlay text/json/jsonb/bytea
CHECK (payload ? 'basket')
```

JSON Schema đầy đủ: extension / app (không built-in schema repository kiểu XML XSD trên PG). SQL Server XML SCHEMA COLLECTION không áp JSON.

`CHECK` + `JSON_PATH_EXISTS` = bắt buộc key. Không thay typed column.

**Ghi chú:** `ISJSON` = 0 với JSON5 / trailing comma. Binary `json`/`jsonb` đã valid. Truncate `nvarchar(4000)` giữa document = invalid im lặng lúc ghi nếu không check.

---

## 12. Worked examples

### 12.1 Đọc scalar vs object

```sql
-- SQL Server
SELECT
    Id,
    JSON_VALUE(Payload, '$.user.name') AS user_name,
    JSON_QUERY(Payload, '$.user') AS user_obj
FROM dbo.Doc;

-- PostgreSQL
SELECT
    id,
    payload #>> '{user,name}' AS user_name,
    payload -> 'user' AS user_obj
FROM doc;
```

### 12.2 Unnest items rồi lọc

```sql
-- SQL Server
SELECT d.Id, j.sku, j.qty
FROM dbo.Doc AS d
CROSS APPLY OPENJSON(d.Payload, '$.items')
WITH (sku nvarchar(32) '$.sku', qty int '$.qty') AS j
WHERE j.qty > 1;

-- PostgreSQL (GIN @> trước nếu lọc document)
SELECT d.id, x.sku, x.qty
FROM doc AS d
CROSS JOIN LATERAL jsonb_to_recordset(d.payload -> 'items')
    AS x(sku text, qty int)
WHERE x.qty > 1;
```

### 12.3 Object agg theo khách

```sql
-- SQL Server PREVIEW on-prem / GA Azure (policy)
SELECT customer_id, JSON_OBJECTAGG(sku: qty RETURNING JSON)
FROM dbo.OrderLines
GROUP BY customer_id;

-- PostgreSQL
SELECT customer_id, jsonb_object_agg(sku, qty)
FROM order_lines
GROUP BY customer_id;
```

### 12.4 Client `json_array()` sau nâng 19

```text
Trước 19:  json_array(SELECT … empty) IS NULL  → nhánh “không có phần tử”
19:        []  → IS NULL = false  → nhánh “có array”
Sửa: kiểm json_typeof(x) = 'array' AND jsonb_array_length(x::jsonb) = 0
  hoặc NULLIF(..., '[]')
Không đụng json_agg
```

### 12.5 Null khi build object/array

`FOR JSON` SQL Server mặc định **bỏ** NULL; `INCLUDE_NULL_VALUES` giữ. Aggregate JSON có `NULL ON NULL` / `ABSENT ON NULL` (tên/chỗ đặt theo Learn). Round-trip API thiếu field vs `"x": null` là bug nghiệp vụ.

### 12.6 lax vs strict (SQL Server path)

Mặc định **lax**: path sai, index mảng vượt biên, `JSON_VALUE` gặp object → `NULL`. `strict`: lỗi statement. Báo cáo “thiếu data” khi path typo là bẫy lax. PG `jsonb_path_query` có `silent` option — khác tên, cùng ý “nuốt”.

JSON INDEX + `JSON_CONTAINS` (**PREVIEW**): không implicit convert số ↔ chuỗi. Containment PG `@>` so cấu trúc jsonb, không phải substring.

### 12.7 Export NDJSON vs array

```sql
-- Stream log: NDJSON
COPY (SELECT id, payload FROM doc WHERE id > 0)
    TO STDOUT WITH (FORMAT json);

-- API một JSON array
COPY (SELECT id, name FROM users ORDER BY id)
    TO STDOUT WITH (FORMAT json, FORCE_ARRAY);
```

### 12.8 Bảng hàm JSON (không bịa)

| Việc | SQL Server | PostgreSQL |
|---|---|---|
| Scalar path | `JSON_VALUE` | `->>` / `#>>` |
| Object/array path | `JSON_QUERY` | `->` / `#>` |
| Tồn tại path | `JSON_PATH_EXISTS` | `jsonb_path_exists` / `?` |
| Containment | `JSON_CONTAINS` **PREVIEW** | `@>` GIN |
| Sửa hàm | `JSON_MODIFY` GA | `jsonb_set` / `\|\|` / `-` |
| Sửa in-place cột typed | `json.modify` **PREVIEW** | không method cột |
| Unnest | `OPENJSON` | `jsonb_to_recordset` / `jsonb_array_elements` |
| Agg object/array | `JSON_OBJECTAGG` / `JSON_ARRAYAGG` **PREVIEW** on-prem | `json[b]_object_agg` / `json[b]_agg` |
| Constructor array từ query | — | `json_array(SELECT …)` — 19: rỗng = `[]` |
| Export stream | `FOR JSON` | `COPY TO (FORMAT json)` **19** |

`JSON_CONTAINS` (PREVIEW): so khớp giá trị tại path; **không** convert số ↔ chuỗi. Wildcard path ANSI **PREVIEW**. `WITH ARRAY WRAPPER` trên `JSON_QUERY` **PREVIEW** — bọc scalar thành array; đối chiếu Learn, đừng bịa trên `JSON_VALUE`.

### 12.9 On-prem vs Azure — checklist migrate schema

```text
1. Cột nvarchar + ISJSON + computed JSON_VALUE + btree  →  portable GA
2. Đổi kiểu json on-prem  →  PREVIEW; rollback kiểu khó; clustered PK nếu JSON INDEX
3. JSON_OBJECTAGG trong view báo cáo  →  Azure GA, on-prem preview → CI hai môi trường
4. Payload.modify  →  chỉ cột json 2025 preview; nvarchar giữ JSON_MODIFY
5. Không bật PREVIEW_FEATURES “cho JSON” nếu không cần vector/CES/fuzzy cùng DB
```

### 12.10 GIN vs btree vs JSON INDEX — chọn

```text
Query: payload->>'status' = 'open'          → btree expression (PG) / computed (SS GA)
Query: payload @> '{"tag":"a"}'           → GIN jsonb_path_ops (PG)
Query: JSON_VALUE / JSON_CONTAINS nhiều path
        + clustered PK + chấp nhận PREVIEW  → JSON INDEX on-prem
Query: tồn tại key ?                       → GIN jsonb_ops, không path_ops
Document 10 MB update 1 key/s               → tách cột; modify PREVIEW chỉ giảm rewrite khi đủ chỗ
```

TOAST/LOB: [internal.md](internal.md) §7. Index chi tiết: [indexes.md](indexes.md) §9.

---



## 13. Best practices & checklist

- Cột ổn định → relational. JSON cho phần còn lại.
- PG: `jsonb` trừ khi phải round-trip bitwise text.
- SS **on-prem**: hiểu **PREVIEW** vs Azure **GA** trước khi `json` + JSON INDEX / agg / `modify` khóa schema.
- Path: `JSON_QUERY` cho object; `JSON_VALUE` scalar. PG `->` vs `->>`.
- Unnest có schema (`WITH` / `jsonb_to_recordset`) — đừng parse text tay.
- Index: một key equality = btree expression; containment = GIN `@>` / JSON INDEX path.
- Aggregate: `RETURNING JSON` khi muốn kiểu `json`; PG 19 `json_array()` rỗng = `[]` ≠ `json_agg` NULL.
- `COPY TO` json: NDJSON mặc định; `FORCE_ARRAY` khi client cần một array.
- Validate lúc ghi (`json` type / `::jsonb` / CHECK path).
- Document lớn: tránh update key sâu từng request — tách bảng; on-prem `modify` in-place chỉ khi PREVIEW chấp nhận.

---

## 14. Bẫy khi review

- Path thiếu `$` trên SS; lax nuốt lỗi, báo cáo NULL.
- `JSON_VALUE` trên object — NULL, tưởng thiếu data.
- `json_array()` upgrade 19: `NULL` → `[]` phá client; nhầm với `json_agg`.
- Duplicate key nvarchar vs jsonb khác nhau.
- `OPENJSON` fan-out × join không LIMIT.
- GIN `jsonb_path_ops` rồi query `?` key existence.
- JSON INDEX path chồng; thiếu clustered PK; JSON INDEX trên heap.
- `JSON_CONTAINS` so chuỗi với số JSON.
- Port `@>` sang T-SQL (không có) hoặc `JSON_MODIFY` sang `||` jsonb (merge khác).
- `FOR JSON` NULL bị drop, round-trip mất field.
- Preview aggregate / `modify` / JSON INDEX / kiểu `json` trên prod **on-prem** như đã GA Azure.
- Cột JSON cho `customer_id` — không FK, không unique.
- `COPY TO` json rồi `json.loads` cả file NDJSON.
- `.modify` trên cột `nvarchar`.
- Vector nhét JSON array thay kiểu `vector`.

---

## 15. Version gates

| Mục | SQL Server | PostgreSQL |
|---|---|---|
| `JSON_VALUE` / `OPENJSON` / `FOR JSON` / `JSON_MODIFY` | 2016+ | — (`->`, `jsonb_to_recordset`, `jsonb_set`) |
| Kiểu `json` native | **2025 PREVIEW on-prem**; **GA Azure** / MI policy 2025 | `json`/`jsonb` lâu |
| `JSON_OBJECT` / `JSON_ARRAY` | 2022+ | `json[b]_build_*` / `json_array()` |
| `JSON_OBJECTAGG` / `JSON_ARRAYAGG` | **2025 PREVIEW on-prem**; GA Azure/Fabric DW | `json[b]_agg` / `object_agg` |
| `CREATE JSON INDEX` / `JSON_CONTAINS` | **2025 PREVIEW** | GIN |
| `json.modify` method | **2025 PREVIEW** | `jsonb_set` |
| Array wildcard path / `WITH ARRAY WRAPPER` | **2025 PREVIEW** | `jsonpath` `[*]` |
| `json_array()` 0 hàng → `[]` | — | **19** breaking |
| `COPY TO` `FORMAT json` / `FORCE_ARRAY` | — | **19** |
| `IS JSON` trên domain | — | **19** nới |
| jsonpath `lower`/`ltrim`/… | — | **19** |

Vector: [indexes.md](indexes.md), [typesystem.md](typesystem.md). Isolation không áp path JSON.

`ISJSON` trên `nvarchar` không biến cột thành kiểu `json`. Ép `CAST(col AS json)` lúc migrate — invalid hàng fail; lọc `ISJSON = 1` trước. PG `json` → `jsonb` mất key trùng / whitespace — dump so sánh checksum text sẽ lệch dù “cùng” document.

---

## Phụ lục A. JSON_CONTAINS & wildcard (PREVIEW on-prem)

`JSON_CONTAINS(json, value, path)` — PREVIEW on-prem; tối ưu cùng JSON INDEX. Value so khớp **kiểu JSON**, không implicit nvarchar `'1'` = số `1`. Path recursive như JSON INDEX: `$.tags` gồm phần tử mảng nếu cấu trúc cho phép — test, đừng giả `@>` PG.

Wildcard mảng ANSI **PREVIEW**: path kiểu `$.items[*].sku` (đối chiếu Learn cú pháp đúng). `JSON_QUERY(..., WITH ARRAY WRAPPER)` **PREVIEW**: khi path ra một phần tử, bọc `[…]` cho client ổn định.

PG: `jsonb_path_query` + `[*]` không PREVIEW. `@>` không wildcard path T-SQL.

```sql
-- SS PREVIEW — đối chiếu Learn nếu CU đổi chữ ký
SELECT JSON_CONTAINS(Payload, N'"open"', '$.status');
SELECT JSON_QUERY(Payload, '$.items[*].sku' WITH ARRAY WRAPPER);

-- PG
SELECT payload @> '{"status":"open"}'::jsonb;
SELECT jsonb_path_query(payload, '$.items[*].sku');
```

---

## Phụ lục B. `json_array()` vs `json_agg` vs `COPY`

```text
json_array(SELECT x FROM t)     0 hàng → []     (19 breaking; trước NULL)
json_agg(x) FROM t              0 hàng, không GROUP BY → NULL
COPY t TO … (FORMAT json)       0 hàng → file rỗng (không [] trừ FORCE_ARRAY trên 0 hàng = [])
FOR JSON PATH                   0 hàng → NULL / rỗng tùy WITHOUT_ARRAY_WRAPPER — test
JSON_ARRAYAGG                   PREVIEW on-prem; GROUP BY 0 nhóm = không hàng
```

Client TypeScript `if (data === null)` với `json_array` 19 = nhánh chết. Contract OpenAPI “null = empty” phải đổi `[]`.

`FORCE_ARRAY` trên bảng rỗng: `[]` (một array rỗng) — khác NDJSON rỗng. Đo trước khi đổi pipeline Spark/NDJSON.

---

## Phụ lục C. In-place `modify` — khi nào rewrite

Learn: chuỗi mới ≤ cũ; số cùng kiểu / trong range → in-place có thể. Chuỗi dài hơn, đổi object thành array, thêm key sâu → rewrite document (LOB). Không hứa “mọi UPDATE json.modify = O(1)”. Đo kích thước cột trước/sau. PG không có method cột; `jsonb_set` gần như luôn tuple mới (MVCC).

---

## Phụ lục D. Migrate `nvarchar` → `json` on-prem

```sql
-- 1. Lọc invalid
SELECT Id FROM dbo.Doc WHERE ISJSON(Payload) = 0;

-- 2. Staging (PREVIEW on-prem — lab)
ALTER TABLE dbo.Doc ADD PayloadJson json NULL;
UPDATE dbo.Doc SET PayloadJson = CAST(Payload AS json);

-- 3. Clustered PK đã có trước JSON INDEX
-- 4. Không DROP nvarchar cùng deploy PREVIEW INDEX
```

Azure: kiểu `json` GA — vẫn test `modify`/INDEX/agg từng mục (một số vẫn preview trên 2025 docs). Rollback on-prem: giữ cột nvarchar đến khi GA. Ép fail cả batch nếu một hàng bẩn — lọc trước.

PG `json` → `jsonb`: `ALTER … TYPE jsonb USING payload::jsonb` — mất key trùng/whitespace; rewrite bảng; `ACCESS EXCLUSIVE` trừ kỹ thuật ẩn (không bịa `CONCURRENTLY` cho ALTER TYPE).

---

## Phụ lục E. `COPY TO` JSON — quyền và format

```sql
COPY (SELECT id, name FROM users ORDER BY id)
    TO STDOUT WITH (FORMAT json);                 -- NDJSON

COPY users TO '/var/lib/pgsql/users.json'
    WITH (FORMAT json, FORCE_ARRAY);              -- quyền server file
```

`\copy` (psql) = file client, không superuser. Format `json` chỉ `TO`. `HEADER`/`DELIMITER` với json = lỗi. Partitioned 19: `COPY TO` bảng cha logical — đối chiếu docs, không giả mỗi partition một file tự động.

Không `COPY FROM json`. Load JSON: `jsonb_populate_record` / `COPY` CSV / app. SS: `OPENJSON` + `INSERT SELECT`, `BULK INSERT` text.

SIMD `COPY FROM` text/CSV 19: throughput; `ON_ERROR SET_NULL` nuốt ô bẩn. Khác JSON export.

---

## Phụ lục F. NULL semantics — sửa document

| Thao tác | SQL Server | PostgreSQL |
|---|---|---|
| `JSON_MODIFY(path, NULL)` lax | **Xóa** key | — |
| `jsonb_set(..., 'null'::jsonb)` | — | Key còn, giá trị JSON null |
| `doc - 'key'` | — | Xóa key |
| `FOR JSON` mặc định | Bỏ SQL NULL | — |
| `json_build_object` | — | Giữ JSON null |

Port “set null = xóa field” phải đọc lại. Round-trip API optional field vs `"x": null`.

---

## Phụ lục G. `JSON_ARRAYAGG` / `RETURNING JSON` — môi trường

```sql
-- PREVIEW on-prem 2025; GA Azure SQL / MI / Fabric DW (policy Learn)
SELECT JSON_ARRAYAGG(sku ORDER BY sku RETURNING JSON)
FROM dbo.Items;

SELECT JSON_OBJECTAGG(sku: qty RETURNING JSON)
FROM dbo.Items;
```

Không `RETURNING JSON` → kiểu nvarchar JSON text (đối chiếu Learn). GROUPING SETS: Learn nói hỗ trợ trên agg JSON — test, đừng giả mọi grouping set. Key trùng: key sau thắng.

PG `jsonb_object_agg` không PREVIEW. `json_array()` constructor ≠ `JSON_ARRAYAGG` T-SQL.

CI: job Azure dùng `JSON_OBJECTAGG` + job on-prem cùng repo → `#if` dialect / feature detect, không copy mù.

---

## Phụ lục H. Path `$` vs `->` — lỗi hay gặp

```sql
-- SS: thiếu $
JSON_VALUE(doc, 'user.name')          -- sai; cần $.user.name
JSON_VALUE(doc, '$.user')             -- object → NULL (lax); dùng JSON_QUERY
JSON_VALUE(doc, 'strict $.missing')   -- lỗi statement

-- PG
doc -> 'user' ->> 'name'              -- text
doc -> 'user' -> 'name'               -- jsonb (có quotes nếu string)
doc @> '{"user":{"name":"Ada"}}'      -- containment, không path T-SQL
```

`JSON_CONTAINS` PREVIEW không thay `@>`. Số JSON vs chuỗi: INDEX/CONTAINS không convert. Wildcard `[*]` PREVIEW on-prem.

Unnest rồi `WHERE sku = …` parse mọi document — đẩy `@>` / `JSON_CONTAINS` / computed trước.

### Document 2 GB

SS `json` ~2 GB/row (PREVIEW on-prem). Update key = rewrite trừ `modify` in-place đủ chỗ. PG TOAST jsonb lớn — `jsonb_set` tuple mới + TOAST. Tách bảng khi update nóng. [internal.md](internal.md) §7.

---

## Phụ lục I. `json_array()` — sửa client

```text
API: GET /items → { "skus": <json_array subquery> }
18: 0 hàng → skus: null     → client if (!skus) empty
19: 0 hàng → skus: []       → if (!skus) không vào; length 0
Sửa: Array.isArray && length === 0
     hoặc NULLIF(json_array(SELECT …), '[]'::json) nếu cần null cũ
Không đổi json_agg / jsonb_agg (vẫn NULL trên empty scalar)
COPY FORCE_ARRAY bảng rỗng: []  — khác NDJSON rỗng
```

`json_array(value, …)` với 0 tham số: `[]` (constructor rỗng), không liên quan subquery breaking. Docs 19: subquery 0 hàng = empty array (SQL/JSON).

`ABSENT ON NULL` trên constructor list (không phải query form — query luôn absent null). Đối chiếu `json_array` signature docs, đừng mix với `JSON_ARRAYAGG` T-SQL.

On-prem 2025: kiểu `json`, JSON INDEX, `JSON_CONTAINS`, agg `RETURNING JSON`, `json.modify` = **PREVIEW**. Azure SQL/MI policy 2025: kiểu `json` **GA**; từng hàm INDEX/agg/modify vẫn đối chiếu Learn. `JSON_VALUE`/`OPENJSON`/`FOR JSON`/`JSON_MODIFY` = GA lâu trên `nvarchar`.

`COPY TO (FORMAT json)` 19: NDJSON mặc định; `FORCE_ARRAY` một array; chỉ TO; không CSV option.

```sql
-- NDJSON (mỗi hàng một object)
COPY (SELECT id, name FROM users ORDER BY id) TO STDOUT WITH (FORMAT json);

-- Một JSON array
COPY (SELECT id, name FROM users ORDER BY id)
    TO STDOUT WITH (FORMAT json, FORCE_ARRAY);
```

Không `COPY FROM json`. Load: `jsonb_populate_record` / CSV / app. SS: `FOR JSON` / `OPENJSON`. Feature flag lệch Azure GA vs on-prem PREVIEW: CI hai môi trường, không một script agg preview trên prod on-prem.

`json_array(SELECT …)` 19: 0 hàng = `[]` (breaking từ `NULL`). `json.modify('$.a', v)` PREVIEW trên cột `json`, không `nvarchar`. JSON INDEX path không chồng; clustered PK bắt buộc.

---

---

## Phụ lục J. Checklist JSON (WHY)

1. **On-prem PREVIEW vs Azure GA** — kiểu `json`/INDEX/agg/`modify` lệch môi trường.
2. **`json_array()` 19: rỗng = `[]`** — client `IS NULL` vỡ; `json_agg` vẫn NULL.
3. **`COPY TO FORMAT json`** — NDJSON; `FORCE_ARRAY` một array; chỉ TO.
4. **JSON INDEX: clustered PK, path không chồng** — không heap.
5. **`.modify` chỉ cột `json`** — `nvarchar` dùng `JSON_MODIFY`.
6. **`JSON_CONTAINS` không convert số/chuỗi**.
7. **GIN `jsonb_path_ops` chỉ `@>`** — tồn tại key cần `jsonb_ops`.
8. **Cột quan hệ cho key ổn định** — JSON không FK.

