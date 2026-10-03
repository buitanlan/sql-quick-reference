# Tài liệu tham khảo SQL

Bộ tài liệu tham chiếu **in-depth / advanced** cho SQL trên hai engine chính: **SQL Server 2025** (T-SQL) và **PostgreSQL 19**. Không phải giáo trình nhập môn: các khái niệm được trình bày dạng tham khảo nhanh kèm chi tiết nâng cao (semantics, dialect gates, isolation, architecture, pitfalls). Nếu chưa biết SQL, bắt đầu bằng [tutorial PostgreSQL](https://www.postgresql.org/docs/19/tutorial.html) hoặc [tutorial T-SQL](https://learn.microsoft.com/en-us/sql/t-sql/tutorial-writing-transact-sql-statements), rồi dùng bộ này để tra cứu sâu hơn.

> **Baseline:** SQL Server **2025** (17.x, GA 18/11/2025, mainstream đến **01/2031**) · PostgreSQL **19** (Beta 4 · 24/09/2026; chưa GA tại lần rà soát **03/10/2026**).<br>
> Mục ghi **PREVIEW** (SQL Server: `PREVIEW_FEATURES`; PostgreSQL 19: beta) chưa dùng cho production.

SQL không phải một ngôn ngữ duy nhất: ANSI/ISO SQL là lõi, mỗi engine thêm dialect (T-SQL vs PostgreSQL). File nào có hai cột/khối `-- SQL Server` / `-- PostgreSQL` là điểm lệch ngữ nghĩa — đừng copy mù.

**Cách đọc bộ này.** Hai khối dialect cạnh nhau **không** nghĩa là cùng guarantee: isolation cùng tên (`REPEATABLE READ`) không portable — [transactions.md](transactions.md). Thứ tự *viết* `SELECT` ≠ *logical processing* — [select.md](select.md). Cùng ý “page / WAL / vacuum” nhưng **kiến trúc khác** — [internal.md](internal.md). API gắn **PREVIEW**/beta có thể đổi hoặc bị rút theo CU hoặc trước GA. Cuối mỗi file: Best practices, **Bẫy khi review**, Version gates — dùng khi review PR, không phải phụ lục.

**Chủ đề trừu tượng.** Isolation, khóa, MVCC, WAL, logical processing, `ON` vs `WHERE`, `NOT IN` + NULL, `CHECK` nuốt NULL, B-tree/sargable, CTE đệ quy, fan-out `UPDATE`, DDL trong transaction, `now()` vs đồng hồ tường, `json` vs `jsonb`, `ROWS` vs `RANGE`, trigger theo tập, `SECURITY DEFINER`, `GRANT`/`DENY`/RLS ([permissions.md](permissions.md)) — dễ hiểu sai nếu chỉ nhớ bảng. Các file đó có mục **Hình dung**: ví dụ đời thường, dòng thời gian, rồi mới tới cú pháp. Đọc Hình dung trước khi copy snippet.

Tính năng theo phiên bản (SQL Server 2025 / PostgreSQL 19) nằm **trong file chủ đề** (vector → typesystem, `REPACK` → ddl, optimized locking → concurrency, …), không tách changelog riêng.

Tham khảo: [SQL Server 2025 what's new](https://learn.microsoft.com/sql/sql-server/what-s-new-in-sql-server-2025) · [T-SQL reference](https://learn.microsoft.com/sql/t-sql) · [PostgreSQL 19 docs](https://www.postgresql.org/docs/19/) · [PostgreSQL 19 release notes](https://www.postgresql.org/docs/19/release-19.html)

---

## Trạng thái phiên bản và cách kiểm chứng

Ngày rà soát: **03/10/2026**. PostgreSQL 19 đang ở [Beta 4](https://www.postgresql.org/about/news/postgresql-19-beta-4-released-3386/); thời điểm GA chưa chốt. Các phần ngôn ngữ ổn định vẫn hữu ích cho PostgreSQL 18, nhưng tính năng ghi **19** cần server 19.

- **Đã rút khỏi 19:** SQL/PGQ (property graph), temporal DML `FOR PORTION OF`, SPLIT/MERGE partition và thay đổi checksum trực tuyến đã bị rút trong Beta 4.
- **`GROUP BY ALL` suy ra cột SELECT:** đã bị rút từ [Beta 3](https://www.postgresql.org/about/news/postgresql-186-1711-1615-1519-1424-and-19-beta-3-released-3365/). PostgreSQL vẫn có `GROUP BY ALL grouping_element` để giữ grouping set trùng; đó là nghĩa khác.
- **SQL Server:** kiểm tra cả build/CU, edition và compatibility level. [Vòng đời SQL Server 2025](https://learn.microsoft.com/en-us/lifecycle/products/sql-server-2025) và [tính năng mới](https://learn.microsoft.com/en-us/sql/sql-server/what-s-new-in-sql-server-2025?view=sql-server-ver17) là nguồn đối chiếu.

Mỗi file có nguồn chính thức ở cuối. Ví dụ có `…`/`...`, tham số hoặc bảng chưa khai báo là **mảnh cú pháp**, cần hoàn thiện trước khi chạy. Các khối chứa hai dialect phải tách theo comment engine. `$1` là tham số PostgreSQL của prepared statement/driver; `:name` là placeholder phía client, không phải cú pháp SQL trực tiếp; `@name` cần khai báo hoặc bind trên SQL Server.

Các [ví dụ SQL Server](examples/sql-server.sql) và [ví dụ PostgreSQL](examples/postgresql.sql) dùng dữ liệu tự khai báo để kiểm tra các bẫy thường gặp. Chạy riêng trong session thử nghiệm. Rà soát này đối chiếu tài liệu và kiểm tra cấu trúc Markdown; không khẳng định mọi snippet đã chạy trên database thật.

Kiểm tra liên kết nội bộ, mục lục và code fence bằng Node.js, không cần cài package:

```powershell
node scripts/check-docs.mjs
```

Sau khi thêm hoặc đổi tiêu đề, chạy `node scripts/check-docs.mjs --write-toc` để tạo lại mục lục cấp 2–3 và kiểm tra liên kết. Script này kiểm cấu trúc tài liệu, không thực thi SQL hoặc kiểm URL ngoài repository.

## Nội dung

### Ngôn ngữ cốt lõi

- [Dialect, identifier & quy ước](dialects.md)
- [Hệ thống kiểu dữ liệu](typesystem.md)
- [Literal](literals.md)
- [Toán tử](operators.md)
- [Từ khóa](keywords.md)
- [SELECT](select.md)
- [JOIN](joins.md)

### Thay đổi dữ liệu & schema

- [DML (INSERT / UPDATE / DELETE / MERGE)](dml.md)
- [DDL (CREATE / ALTER / DROP)](ddl.md)
- [Ràng buộc](constraints.md)
- [Chỉ mục](indexes.md)

### Biểu thức & chương trình

- [Hàm](functions.md)
- [Window function](window-functions.md)
- [CTE & subquery](cte-subqueries.md)
- [Routine (procedure, function, trigger)](routines.md)
- [Quyền](permissions.md)

### Engine

- [Kiến trúc nội bộ — giống và khác](internal.md)
- [Giao dịch & isolation](transactions.md)
- [Khóa & concurrency](concurrency.md)
- [JSON](json.md)
