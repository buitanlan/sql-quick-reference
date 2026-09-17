# Tài liệu tham khảo SQL

Bộ tài liệu tham chiếu **in-depth / advanced** cho SQL trên hai engine chính: **SQL Server 2025** (T-SQL) và **PostgreSQL 19**. Không phải giáo trình nhập môn: các khái niệm được trình bày dạng tham khảo nhanh kèm chi tiết nâng cao (semantics, dialect gates, isolation, architecture, pitfalls). Nếu chưa biết SQL, bắt đầu bằng tutorial chính thức bên dưới, rồi dùng bộ này khi cần tra cứu sâu hơn.

> **Baseline:** SQL Server **2025** (17.x, GA 18/11/2025, mainstream đến **01/2031**) · PostgreSQL **19** (Beta 3 · 08/2026; GA dự kiến **cuối 10/2026**).  
> Mục ghi **PREVIEW** (SQL Server: `PREVIEW_FEATURES`; PostgreSQL 19: beta) chưa dùng cho production.

SQL không phải một ngôn ngữ duy nhất: ANSI/ISO SQL là lõi, mỗi engine thêm dialect (T-SQL vs PostgreSQL). File nào có hai cột/khối `-- SQL Server` / `-- PostgreSQL` là điểm lệch ngữ nghĩa — đừng copy mù.

**Cách đọc bộ này.** Hai khối dialect cạnh nhau **không** nghĩa là cùng guarantee: isolation cùng tên (`REPEATABLE READ`) không portable — [transactions.md](transactions.md). Thứ tự *viết* `SELECT` ≠ *logical processing* — [select.md](select.md). Cùng ý “page / WAL / vacuum” nhưng **kiến trúc khác** — [internal.md](internal.md). API gắn **PREVIEW**/beta có thể đổi theo CU hoặc trước GA. Cuối mỗi file: Best practices, **Bẫy khi review**, Version gates — dùng khi review PR, không phải phụ lục.

**Chủ đề trừu tượng.** Isolation, khóa, MVCC, logical processing, `ON` vs `WHERE`, `NOT IN` + NULL, `CHECK` nuốt NULL — dễ hiểu sai nếu chỉ nhớ bảng. Các file đó có mục **Hình dung**: ví dụ đời thường, dòng thời gian hai session, rồi mới tới cú pháp. Đọc Hình dung trước khi copy snippet.

Tính năng theo phiên bản (SQL Server 2025 / PostgreSQL 19) nằm **trong file chủ đề** (vector → typesystem, `REPACK` → ddl, optimized locking → concurrency, …), không tách changelog riêng.

Tham khảo: [SQL Server 2025 what's new](https://learn.microsoft.com/sql/sql-server/what-s-new-in-sql-server-2025) · [T-SQL reference](https://learn.microsoft.com/sql/t-sql) · [PostgreSQL 19 docs](https://www.postgresql.org/docs/19/) · [PostgreSQL 19 release notes](https://www.postgresql.org/docs/19/release-19.html)

---

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

### Engine

- [Kiến trúc nội bộ — giống và khác](internal.md)
- [Giao dịch & isolation](transactions.md)
- [Khóa & concurrency](concurrency.md)
- [JSON](json.md)
