# Quyền (Permissions)

> **Baseline:** SQL Server **2025** (17.x) · PostgreSQL **19**.  
> File này là **ủy quyền** (ai được làm gì sau khi đã vào được). Xác thực (mật khẩu, Entra, `pg_hba`, TLS) chỉ nhắc khi nó đổi principal. Routine `SECURITY DEFINER` / `EXECUTE AS`: [routines.md](routines.md) §11. Kiến trúc login/TDE: [internal.md](internal.md) §18.

`GRANT SELECT` trên hai engine **không** cùng mô hình principal. SQL Server tách **login** (cửa instance) và **user** (cửa database), có `DENY` thắng `GRANT`. PostgreSQL chỉ có **role**; “user” là role có `LOGIN`. Không có `DENY`: muốn cấm thì `REVOKE`, hoặc đừng cho vào role đang giữ quyền. Copy script `DENY` sang `psql` là lỗi cú pháp, không phải “cấm được”.

---

## Mục lục

- [1. Tổng quan \& triết lý](#1-tổng-quan--triết-lý)
  - [1.1 Hình dung: danh tính vs chìa khóa](#11-hình-dung-danh-tính-vs-chìa-khóa)
- [2. Principal](#2-principal)
- [3. `GRANT` / `REVOKE` / `DENY`](#3-grant--revoke--deny)
- [4. `PUBLIC` và quyền mặc định](#4-public-và-quyền-mặc-định)
- [5. Schema: `USAGE` vs `ON SCHEMA`](#5-schema-usage-vs-on-schema)
- [6. Ownership, view, chaining](#6-ownership-view-chaining)
- [7. Routine: `EXECUTE` và definer](#7-routine-execute-và-definer)
- [8. Row-level security](#8-row-level-security)
- [9. Cột, sequence, large object](#9-cột-sequence-large-object)
- [10. Role dựng sẵn](#10-role-dựng-sẵn)
- [11. Mạo danh](#11-mạo-danh)
- [12. App role tối thiểu](#12-app-role-tối-thiểu)
- [13. SQL Server 2025 \& PostgreSQL 19](#13-sql-server-2025--postgresql-19)
- [14. Worked examples](#14-worked-examples)
- [15. Best practices \& checklist](#15-best-practices--checklist)
- [16. Bẫy khi review](#16-bẫy-khi-review)
- [17. Version gates](#17-version-gates)

---

## 1. Tổng quan & triết lý

Ba lớp, đừng trộn:

| Lớp | Câu hỏi | SQL Server | PostgreSQL |
|---|---|---|---|
| Xác thực | Đây có phải người đó? | Login SQL / Windows / Entra, TDS 8 | `pg_hba.conf`, SCRAM, cert, peer |
| Ủy quyền | Người đó được đụng object nào? | User + role + `GRANT`/`DENY` | Role + `GRANT`/`REVOKE` |
| Hàng | Trong bảng được đọc, thấy hàng nào? | RLS security policy | `CREATE POLICY` |

`db_owner` / `superuser` không phải “role app”. App pool nên là principal **không** sở hữu bảng: chỉ `SELECT`/`INSERT`/`UPDATE`/`DELETE`/`EXECUTE` đúng chỗ. Owner bypass một số kiểm tra (view, RLS) — mục 6 và 8.

### 1.1 Hình dung: danh tính vs chìa khóa

```text
SQL Server
  Login  = thẻ vào tòa (instance). Chưa vào được phòng database.
  User   = thẻ phòng (database), map từ login.
  Role   = chùm chìa. User nhận chùm, không nhận từng chìa.
  DENY   = biển cấm trên một cửa, thắng mọi chùm chìa (trừ sysadmin).

PostgreSQL
  Role   = vừa người vừa nhóm. LOGIN = được gõ cửa cluster.
  Không có user tách login. GRANT role TO role = đưa chùm chìa.
  Không có biển cấm. Muốn cấm: lấy chìa ra (REVOKE), hoặc đừng đưa chùm.
```

Một người có hai chùm chìa: chỉ cần **một** chùm có `SELECT` là đọc được. `REVOKE SELECT` khỏi chùm A không có tác dụng nếu chùm B vẫn có. SQL Server `DENY` thì khác: biển cấm chặn cả hai chùm.

---

## 2. Principal

### 2.1 SQL Server: login, user, role

```sql
CREATE LOGIN app_login WITH PASSWORD = N'…';   -- cửa instance
CREATE USER app_user FOR LOGIN app_login;       -- trong database hiện tại
CREATE ROLE app_read;
ALTER ROLE app_read ADD MEMBER app_user;

-- Entra (2025): tên hiển thị có thể trùng
CREATE LOGIN [Ada Nguyen] FROM EXTERNAL PROVIDER
    WITH OBJECT_ID = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
```

User **không** map login: contained database user, hoặc user không login (chỉ cho chứng chỉ / `EXECUTE AS`). `guest` mặc định tắt — đừng bật để “cho lạ vào”.

`sysadmin` bỏ qua `DENY`. `db_owner` không bỏ qua `DENY` của user khác trên object, nhưng sở hữu database nên gần như làm được mọi việc schema. Đừng nhét app vào `db_owner` “cho nhanh”.

### 2.2 PostgreSQL: một catalog role

```sql
CREATE ROLE app_login LOGIN PASSWORD '…';
CREATE ROLE app_read NOLOGIN;
GRANT app_read TO app_login;

-- Cùng ý, cú pháp cũ
CREATE USER app_login PASSWORD '…';    -- = CREATE ROLE … LOGIN
```

Role có attribute: `LOGIN`, `SUPERUSER`, `CREATEDB`, `CREATEROLE`, `INHERIT`, `BYPASSRLS`, `REPLICATION`. `SUPERUSER` bỏ qua GRANT và (cả `FORCE`) RLS.

**Kế thừa (PG 16+):** attribute `INHERIT` của role nhận **và** tùy chọn trên từng `GRANT role`.

```sql
GRANT app_read TO app_login;                         -- kế thừa quyền app_read
GRANT app_admin TO app_login WITH INHERIT FALSE;    -- phải SET ROLE app_admin mới dùng
SET ROLE app_admin;
```

`INHERIT FALSE`: user *là* member nhưng quyền nhóm **không** tự bật. Hữu ích cho role phá dữ liệu (`DROP`) — chỉ bật khi cố ý `SET ROLE`. `WITH ADMIN OPTION` / `WITH ADMIN TRUE` cho phép trao membership cho người khác.

Không có database-user riêng. Quyền bảng nằm trong database đang kết nối; role thì **cả cluster** (nhìn thấy ở mọi DB, quyền object thì không).

---

## 3. `GRANT` / `REVOKE` / `DENY`

```sql
-- SQL Server
GRANT SELECT, INSERT ON dbo.Orders TO app_read;
GRANT EXECUTE ON dbo.GetOrder TO app_read;
DENY DELETE ON dbo.Orders TO app_read;
REVOKE INSERT ON dbo.Orders FROM app_read;     -- gỡ GRANT, không gỡ DENY
REVOKE DELETE ON dbo.Orders FROM app_read;     -- gỡ DENY (và GRANT nếu có)

-- PostgreSQL
GRANT SELECT, INSERT ON orders TO app_read;
GRANT EXECUTE ON FUNCTION get_order(int) TO app_read;
REVOKE INSERT ON orders FROM app_read;
```

| | SQL Server | PostgreSQL |
|---|---|---|
| Cấm tường minh | `DENY` thắng `GRANT` | Không có. `REVOKE` đến khi không còn đường nào |
| Trao tiếp | `WITH GRANT OPTION` | `WITH GRANT OPTION` |
| Ai ghi ACL | Principal thực thi | `GRANTED BY role` (**19**) nếu không phải current user |
| Sở hữu | `ALTER AUTHORIZATION` | `ALTER … OWNER TO` |
| Mọi bảng schema | `GRANT SELECT ON SCHEMA::app TO role` | `GRANT SELECT ON ALL TABLES IN SCHEMA app TO role` |

`GRANT` trên schema SQL Server **bao gồm object hiện có và object tạo sau** trong schema đó (quyền schema-level). PostgreSQL `ON ALL TABLES` chỉ bảng **đã có**. Bảng tạo ngày mai cần `ALTER DEFAULT PRIVILEGES` (mục 5).

`WITH GRANT OPTION`: người nhận được `GRANT` tiếp. Thu hồi người gốc có thể `CASCADE` (PG) kéo theo người được trao tiếp. SQL Server: `REVOKE … CASCADE` tương tự. App role **không** cần grant option.

**Hình dung `DENY`.** User thuộc `app_read` (`SELECT`) và `intern` (`DENY SELECT` trên `Salary`). Kết quả: **không** đọc `Salary`. Trên PostgreSQL, membership cả hai role mà chỉ một role có `SELECT` thì **vẫn đọc**. Muốn “intern không xem lương”: đừng `GRANT` role có quyền đó, hoặc RLS (mục 8), không có biển `DENY`.

---

## 4. `PUBLIC` và quyền mặc định

`PUBLIC` / `public` là **mọi người đã vào được**, không phải schema tên `public`.

| Mặc định hay dính | SQL Server | PostgreSQL |
|---|---|---|
| Mọi user thuộc | Database role `public` | Pseudo-role `PUBLIC` |
| Bảng mới | Không cấp cho `public` | Không cấp cho `PUBLIC` (owner giữ) |
| Hàm mới | Không `EXECUTE` cho `public` | **`EXECUTE` cấp cho `PUBLIC`** — footgun |
| Database | User phải được map | `CONNECT` trên DB thường cấp sẵn cho `PUBLIC` |
| Schema `public` | `dbo` không tự mở cho mọi login | PG **15+**: `CREATE` trên schema `public` **không** còn cho `PUBLIC`; `USAGE` vẫn có |

```sql
-- PostgreSQL: đóng EXECUTE mặc định cho hàm nhạy
REVOKE ALL ON FUNCTION check_password(text, text) FROM PUBLIC;

-- Đóng CONNECT nếu không muốn mọi role vào DB
REVOKE CONNECT ON DATABASE appdb FROM PUBLIC;
GRANT CONNECT ON DATABASE appdb TO app_login;
```

SQL Server: đừng `GRANT` cho role `public`. User không map trong DB không vào được (trừ `guest`).

**Ghi chú:** Extension tạo hàm trong schema `public` + `EXECUTE` cho `PUBLIC` = mọi login gọi được. Review `CREATE FUNCTION` luôn kèm `REVOKE FROM PUBLIC` khi hàm không dành cho mọi người.

---

## 5. Schema: `USAGE` vs `ON SCHEMA`

**Hình dung PostgreSQL:** schema là **hành lang**. `USAGE` = được đi hành lang và *nhìn thấy* biển tên bảng. `SELECT` trên bảng = chìa phòng. Thiếu một trong hai → không đọc, dù cái kia đã có.

```sql
GRANT USAGE ON SCHEMA app TO app_read;
GRANT SELECT ON ALL TABLES IN SCHEMA app TO app_read;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA app TO app_read;

ALTER DEFAULT PRIVILEGES IN SCHEMA app
    GRANT SELECT ON TABLES TO app_read;
-- Chạy bởi role sẽ CREATE TABLE (thường owner migration), không phải bởi app_read.
```

`ALTER DEFAULT PRIVILEGES` gắn với **role tạo object**. Migration chạy bằng `migrator`, app chạy bằng `app_read`: default privileges phải `FOR ROLE migrator` (hoặc chính migrator chạy lệnh). Chạy bằng superuser rồi tạo bảng bằng migrator = default không áp.

SQL Server không có `USAGE`:

```sql
GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA::app TO app_read;
GRANT EXECUTE ON SCHEMA::app TO app_read;
```

Quyền schema áp cho object tạo sau. `DENY` trên schema chặn luôn object bên trong.

`search_path` (PG) không cấp quyền. Nó chỉ chọn schema nào được thử trước khi báo “không tồn tại” — có thể **che** bảng thật bằng object cùng tên ở schema trước. [dialects.md](dialects.md), [routines.md](routines.md).

---

## 6. Ownership, view, chaining

Owner làm được hầu hết việc trên object mình sở hữu, không cần `GRANT` cho chính mình.

### 6.1 View

```text
PostgreSQL (mặc định, security_invoker = false)
  Người gọi cần quyền trên VIEW, không cần quyền bảng dưới.
  View chạy bằng quyền owner khi đọc bảng dưới.
  Giống “cửa trước”: bảo vệ chỉ kiểm tra vé view.

PostgreSQL 15+: WITH (security_invoker = true)
  Người gọi phải có quyền từng bảng dưới. View không nâng quyền.

SQL Server
  Ownership chaining: view và bảng CÙNG owner
    → caller chỉ cần SELECT trên view.
  Khác owner → caller cần quyền cả bảng dưới.
  Cross-database chaining mặc định TẮT.
```

```sql
-- PostgreSQL: view không nâng quyền
CREATE VIEW app.orders_open
WITH (security_invoker = true) AS
SELECT * FROM app.orders WHERE status = 'open';

-- SQL Server: chaining khi cùng owner (thường dbo)
CREATE VIEW dbo.OrdersOpen AS
SELECT * FROM dbo.Orders WHERE Status = N'open';
GRANT SELECT ON dbo.OrdersOpen TO app_read;
-- app_read không cần SELECT trên dbo.Orders, nếu cùng owner
```

View thường là **hàng rào** (ẩn cột lương) chỉ khi caller **không** có `SELECT` thẳng bảng. `security_invoker = true` hoặc khác owner phá hàng rào đó — đúng cho “view tiện”, sai cho “view che cột”.

`GRANT SELECT` trên view không tự che cột nếu user cũng được `SELECT` bảng gốc.

### 6.2 Procedure như hàng rào (SQL Server)

Stored procedure cùng owner với bảng: caller chỉ cần `EXECUTE`. Đây là chaining, không phải `EXECUTE AS`. Dynamic SQL **bên trong** proc cắt chaining — câu trong `sp_executesql` kiểm tra quyền **caller** (trừ `EXECUTE AS`).

PostgreSQL function mặc định `SECURITY INVOKER`: caller cần quyền bảng dưới, dù chỉ `GRANT EXECUTE`. Muốn hàng rào: `SECURITY DEFINER` + `search_path` khóa — [routines.md](routines.md) §11.

---

## 7. Routine: `EXECUTE` và definer

```sql
GRANT EXECUTE ON dbo.GetOrder TO app_read;                 -- SS: thường đủ nếu chaining
GRANT EXECUTE ON FUNCTION app.get_order(int) TO app_read; -- PG: invoker vẫn cần quyền bảng
```

| | Invoker (mặc định) | Definer |
|---|---|---|
| SQL Server | `EXECUTE AS CALLER` | `EXECUTE AS OWNER` |
| PostgreSQL | `SECURITY INVOKER` | `SECURITY DEFINER` |
| Ai bị kiểm tra trên bảng | Người gọi | Chủ routine |
| Rủi ro | User cần GRANT rộng | Lệch `search_path` / SQL động = leo quyền |

`EXECUTE` **không** thay `GRANT` bảng khi function là invoker. App chỉ được `EXECUTE` + definer an toàn **hoặc** invoker + GRANT đúng bảng — đừng cấp cả hai “cho chắc” (definer + user cũng `db_owner`).

Trigger chạy trong quyền của người gây DML (kiểm tra quyền trigger owner trên một số đường). Đừng nhét `SECURITY DEFINER` vào trigger chỉ để “ghi audit” nếu audit table có thể bị gọi từ hàm lệch path.

---

## 8. Row-level security

RLS lọc **hàng**, không thay `GRANT`. User không có `SELECT` thì RLS không chạy. User có `SELECT` thì chỉ thấy hàng policy cho qua.

### 8.1 Hình dung

Bảo vệ cửa (`GRANT`) cho vào phòng hồ sơ. RLS là **ngăn tủ**: cùng phòng, mỗi người chỉ kéo ngăn `tenant_id` của mình. Chìa phòng không mở ngăn người khác.

### 8.2 PostgreSQL

```sql
ALTER TABLE app.orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.orders FORCE ROW LEVEL SECURITY;   -- owner cũng bị lọc

CREATE POLICY orders_tenant ON app.orders
    USING (tenant_id = current_setting('app.tenant')::int)
    WITH CHECK (tenant_id = current_setting('app.tenant')::int);

-- Mỗi request, sau khi login app_read:
SELECT set_config('app.tenant', '42', true);   -- true = chỉ transaction hiện tại
```

| Ai | RLS |
|---|---|
| Superuser, `BYPASSRLS` | Luôn bỏ qua, kể cả `FORCE` |
| Owner bảng | Bỏ qua **trừ khi** `FORCE ROW LEVEL SECURITY` |
| Role khác | Policy `USING` (đọc) / `WITH CHECK` (ghi) |

Không policy nào mà RLS bật: **không thấy hàng** (mặc định deny khi không có policy permissive). Policy `PERMISSIVE` cộng OR; `RESTRICTIVE` cộng AND.

`BYPASSRLS` trên role migration/admin là cố ý. Role app **không** có attribute này.

### 8.3 SQL Server

```sql
CREATE FUNCTION dbo.fn_tenant(@TenantId int)
RETURNS TABLE
WITH SCHEMABINDING
AS RETURN
    SELECT 1 AS ok
    WHERE @TenantId = CAST(SESSION_CONTEXT(N'tenant') AS int);
GO

CREATE SECURITY POLICY dbo.pol_orders
ADD FILTER PREDICATE dbo.fn_tenant(TenantId) ON dbo.Orders,
ADD BLOCK PREDICATE dbo.fn_tenant(TenantId) ON dbo.Orders
WITH (STATE = ON);
GO

EXEC sys.sp_set_session_context @key = N'tenant', @value = 42;
```

`FILTER` = hàng thấy khi `SELECT`. `BLOCK` = chặn `INSERT`/`UPDATE`/`DELETE` ra ngoài tenant. Thiếu `BLOCK`: user sửa được hàng họ không thấy (kéo sang tenant khác) nếu biết khóa.

**Khác PostgreSQL:** `dbo` / `db_owner` **không** tự bỏ qua RLS. Muốn admin thấy hết thì predicate trả `1` cho role đó, hoặc `STATE = OFF` lúc bảo trì. Đừng giả định “owner như PG”.

Predicate nên `SCHEMABINDING`, inline, không gọi UDF nặng. Policy là nơi rò tenant nếu `SESSION_CONTEXT` do **client** tự set mà không có login trung gian tin cậy. App tự gửi tenant = user đổi được. Đặt context trong proc `EXECUTE AS` hoặc middleware một đường, không tin connection string của từng tenant dùng chung user.

---

## 9. Cột, sequence, large object

```sql
-- Chỉ đọc vài cột (cả hai)
GRANT SELECT (id, status) ON orders TO app_read;

-- PostgreSQL: nextval cần USAGE trên sequence (identity nằm trên sequence ẩn)
GRANT USAGE ON SEQUENCE orders_id_seq TO app_write;

-- SQL Server: INSERT vào IDENTITY không cần quyền riêng trên sequence;
-- sequence độc lập: GRANT UPDATE ON dbo.OrderNo TO app_write;  -- NEXT VALUE cần UPDATE
```

`INSERT` không kèm quyền `SELECT` thì `RETURNING` / `OUTPUT` có thể cần thêm `SELECT` (đặc biệt PG: `RETURNING` đòi `SELECT` trên cột trả về). Test, đừng giả định `INSERT` đủ.

Large object (PG): `pg_read_all_data` / `pg_write_all_data` từ **19** đọc/ghi LO, phục vụ `pg_dump` không superuser. Trước đó hai role này không đụng `pg_largeobject`. SQL Server file `varbinary` nằm trong quyền bảng, không catalog LO riêng.

---

## 10. Role dựng sẵn

### 10.1 Đừng đưa app vào role “tất cả”

| Việc app cần | SQL Server | PostgreSQL |
|---|---|---|
| Đọc mọi bảng | `db_datareader` — rộng, tránh nếu chỉ vài schema | `pg_read_all_data` — mọi bảng mọi schema |
| Ghi mọi bảng | `db_datawriter` | `pg_write_all_data` |
| Sở hữu DB | `db_owner` | owner database / `SUPERUSER` |
| Đọc metadata hiệu năng | `##MS_ServerPerformanceStateReader##` (**2025**, thay Purview) | `pg_monitor` / `pg_read_all_stats` |

`db_datareader` thấy cả bảng lương mới tạo ngày mai. Role tự tạo + `GRANT` từng schema hẹp hơn.

### 10.2 SQL Server 2025 — role thay Purview policy

Purview access policies (DevOps / data owner) **ngừng**. Map:

| Policy cũ | Role |
|---|---|
| Performance monitoring | `##MS_ServerPerformanceStateReader##`, `##MS_PerformanceDefinitionReader##` |
| Security auditing | `##MS_ServerSecurityStateReader##`, `##MS_SecurityDefinitionReader##` |
| Vào DB không cần user trong DB | `##MS_DatabaseConnector##` |

Đây là server role cho vận hành, không phải role ứng dụng.

### 10.3 PostgreSQL 19

`pg_read_all_data` / `pg_write_all_data` đọc/ghi large object (mục 9). `pg_read_all_data` vẫn không phải superuser: không `BYPASSRLS` trừ khi cấp thêm. RLS vẫn lọc role này nếu không `BYPASSRLS`.

---

## 11. Mạo danh

```sql
-- SQL Server
EXECUTE AS USER = N'app_user';
SELECT * FROM dbo.Orders;
REVERT;

-- PostgreSQL
SET ROLE app_read;
SELECT * FROM orders;
RESET ROLE;
```

Dùng để **test** quyền, không để app production nhảy role tùy request nếu không kiểm soát. `SET ROLE` chỉ tới role mình là member. `EXECUTE AS` đòi `IMPERSONATE`.

Chuỗi: middleware `EXECUTE AS` / `SET ROLE` rồi quên `REVERT` trên connection pool → request sau mang quyền request trước. Pool phải reset session (`sp_reset_connection` không gỡ hết mọi context; PG pool nên `DISCARD ALL` / reset role).

---

## 12. App role tối thiểu

```text
migrator   CREATE trên schema app, owner bảng. Không phải user runtime.
app_read   USAGE + SELECT
app_write  USAGE + SELECT/INSERT/UPDATE/DELETE trên bảng nghiệp vụ, không DROP
app_exec   EXECUTE hàm/proc hàng rào; không GRANT bảng nếu definer đã đủ
```

Runtime **không** owner, **không** `CREATEDB`/`CREATEROLE`/`SUPERUSER`/`sysadmin`/`db_owner`. Migration và runtime hai login. Secret nằm ngoài GRANT (vault); `GRANT` không giấu connection string.

RLS + một login app: mọi tenant dùng chung `app_write`, policy theo session tenant. Lợi: ít login. Hại: bug `set_config` = lộ tenant khác. Login-per-tenant chỉ hợp khi số tenant nhỏ.

---

## 13. SQL Server 2025 & PostgreSQL 19

**SQL Server 2025**

- Mật khẩu SQL login hash **PBKDF2** mặc định. Failover login cũ: test, không chỉ backup.
- Entra `CREATE LOGIN … WITH OBJECT_ID` khi tên hiển thị trùng.
- Password policy tùy chỉnh trên **Linux**.
- Role `##MS_*##` thay Purview (mục 10.2).
- Không có từ khóa quyền mới kiểu `DENY` phiên bản 2.

**PostgreSQL 19**

- `GRANT` / `REVOKE … GRANTED BY role` — ACL ghi nhận người cấp không phải lúc nào cũng là current user (role member có quyền).
- Cảnh báo mật khẩu sắp hết hạn: `password_expiration_warning_threshold` (mặc định bảy ngày).
- `pg_read_all_data` / `pg_write_all_data` + large object.
- Property graph: cần quyền trên **bảng** dưới và quyền dùng graph. `GRANT` bảng không tự suy ra `GRAPH_TABLE` nếu thiếu quyền graph — đối chiếu docs 19 `GRANT`, đừng bịa tên privilege. Beta đến GA.
- `SECURITY DEFINER` + `search_path`: không đổi luật 19; vẫn bắt buộc khóa path.

---

## 14. Worked examples

### 14.1 Tách migrator và app (PostgreSQL)

```sql
CREATE ROLE migrator LOGIN PASSWORD '…';
CREATE ROLE app_login LOGIN PASSWORD '…';
CREATE ROLE app_read NOLOGIN;
GRANT app_read TO app_login;

CREATE SCHEMA app AUTHORIZATION migrator;
REVOKE CREATE ON SCHEMA app FROM PUBLIC;

GRANT USAGE ON SCHEMA app TO app_read;

ALTER DEFAULT PRIVILEGES FOR ROLE migrator IN SCHEMA app
    GRANT SELECT ON TABLES TO app_read;

-- migrator tạo bảng sau lệnh trên → app_read có SELECT
-- hàm: REVOKE EXECUTE FROM PUBLIC rồi GRANT cho đúng role
```

### 14.2 Cùng ý (SQL Server)

```sql
CREATE ROLE app_read;
CREATE ROLE app_write;
ALTER ROLE app_read ADD MEMBER app_user;

GRANT SELECT ON SCHEMA::app TO app_read;
GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA::app TO app_write;
GRANT EXECUTE ON SCHEMA::app TO app_write;

DENY DELETE ON app.Audit TO app_write;   -- ghi audit qua proc, không xóa
```

### 14.3 Vì sao `DENY` không port

```text
SS:  GRANT SELECT qua role A, DENY SELECT qua role B → không đọc
PG:  GRANT SELECT qua role A, không GRANT qua role B → vẫn đọc
```

Port “intern không xem Salary”: bỏ membership role có `SELECT` trên `Salary`, hoặc `REVOKE`, hoặc policy RLS `USING (NOT intern)`, không dịch `DENY` thành `REVOKE` trên một role rồi dừng.

### 14.4 View che cột lương

```sql
-- PostgreSQL: security_invoker mặc định false — owner đọc bảng, caller chỉ cần view
REVOKE ALL ON app.employees FROM app_read;
GRANT SELECT ON app.employees_public TO app_read;   -- view không có cột salary

-- Nếu bật security_invoker, app_read cần SELECT bảng gốc → thấy cả salary. Đừng bật.
```

---

## 15. Best practices & checklist

- Hai login: migration và runtime.
- Role theo việc (`app_read`), user là member, không `GRANT` thẳng từng user.
- PostgreSQL: `REVOKE EXECUTE FROM PUBLIC` trên hàm không công khai; `USAGE` + `GRANT` bảng; `ALTER DEFAULT PRIVILEGES` bằng đúng role tạo bảng.
- SQL Server: quyền schema thay vì từng bảng nếu cả schema cùng mức; `DENY` chỉ khi cần chặn role rộng.
- View/proc là hàng rào chỉ khi caller **không** có quyền bảng dưới.
- RLS: `FORCE` (PG) hoặc nhớ dbo không bypass (SS); có `WITH CHECK` / `BLOCK`, không chỉ filter.
- Session tenant không do client tự khai nếu user DB dùng chung.
- Test bằng `SET ROLE` / `EXECUTE AS`, không bằng superuser/`sa`.
- Connection pool reset role và `session_context`.

---

## 16. Bẫy khi review

- App connection là `sa`, `postgres`, `db_owner`, `SUPERUSER`.
- `GRANT ALL ON SCHEMA public TO app` hoặc `db_datareader` “tạm”.
- Hàm PG mới quên `REVOKE FROM PUBLIC`.
- `ALTER DEFAULT PRIVILEGES` chạy nhầm role → bảng migrator tạo ra app không đọc được (hoặc ngược lại, public đọc được).
- View `security_invoker = true` trên view định che cột.
- `DENY` dịch sang PG bằng một `REVOKE` trong khi user còn role khác.
- RLS không `FORCE` và app login là **owner** bảng (PG: owner bỏ qua policy).
- RLS SQL Server chỉ `FILTER`, không `BLOCK` → `UPDATE` kéo hàng sang tenant khác.
- `EXECUTE` function invoker nhưng không `GRANT` bảng → production lỗi; hoặc cấp `pg_read_all_data` cho xong.
- `SECURITY DEFINER` không `SET search_path` — [routines.md](routines.md).
- Dynamic SQL trong proc owner: chaining đứt, hoặc `EXECUTE AS OWNER` + nối chuỗi = leo quyền.
- Pool không `REVERT` / `RESET ROLE`.
- Graph `GRANT` bảng rồi gọi `GRAPH_TABLE` — thiếu quyền graph (19).

---

## 17. Version gates

| Mục | SQL Server | PostgreSQL |
|---|---|---|
| `DENY` | Có | Không |
| `security_invoker` view | Chaining theo owner | **15+** tùy chọn; mặc định invoker **tắt** |
| `INHERIT` từng membership | Role membership luôn “có quyền” (trừ `DENY`) | **16+** `WITH INHERIT FALSE` |
| Schema `public` không `CREATE` cho mọi người | N/A (`dbo`) | **15+** |
| RLS owner bypass | **Không** bypass sẵn | Có, trừ `FORCE`; superuser/`BYPASSRLS` luôn bypass |
| `ALTER DEFAULT PRIVILEGES` | Quyền `ON SCHEMA` phủ object mới | Cần, theo role tạo object |
| PBKDF2, Entra `OBJECT_ID`, `##MS_*##` | **2025** | — |
| `GRANTED BY`, LO cho `pg_read_all_data` | — | **19** |
| Cảnh báo hết hạn mật khẩu | Policy Windows / Linux 2025 | **19** `password_expiration_warning_threshold` |

Từ khóa `GRANT` ngắn: [keywords.md](keywords.md) §18. Definer và `search_path`: [routines.md](routines.md) §11.
