# 原始代码与旧版证据

这些文件不在当前运行顺序中，请从上级 sql/README.md 进入。

- navicat_funnel_user_supplied_20260922.sql：用户本次提供的 MySQL 代码逐字节原文，保留粘贴中的缺失/全角分号和动态边界。
- 04_funnel_user_product.stg_before_20260922.sql：本次更新前的 stg_* 路径脚本。
- 02_import_validation.index_test_before_20260922.sql：恢复导入对账前的索引测试内容。

当前 04/05 整理版以用户原文为依据，保留实际 tem_* 表名及 *_cn 字段名。原始代码中的 DROP TABLE、CREATE INDEX 等语句不是归档后需要重新执行的待办。
