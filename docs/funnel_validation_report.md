# 已完成漏斗工作的归档与复核记录

日期：2026-09-22。范围：已完成的无窗口漏斗、首次严格转化耗时、窗口覆盖率和正式 7 天漏斗。周留存尚未开展。

**状态：用户原始 SQL 已归档，整理版与补充验证 SQL 已保存，清洗明细全量独立复核通过。整理后的 SQL 本次未连接 MySQL 执行。**

## 代码依据与实际改动

用户本次提供了其在 MySQL 中运行的完整代码，已逐字节保存为 [navicat_funnel_user_supplied_20260922.sql](../sql/archive/navicat_funnel_user_supplied_20260922.sql)。该文件作为原始证据，不作为一键运行入口。

[04_funnel_user_product.sql](../sql/04_funnel_user_product.sql) 按原代码归档首次浏览、浏览后加购、两个购买分支和路径检查。[05_funnel_metrics.sql](../sql/05_funnel_metrics.sql) 归档剩余指标计算。保留实际 tem_* 表名、time_step 及用户表 *_cn 字段名。

去除归档说明后的正文差异见 [代码差异](../sql/archive/normalized_changes.diff)。整理版与原文的差异仅包括：

1. 将一处全角分号改为英文分号；给 SELECT * FROM tem_funnel_a、SELECT * FROM tem_funnel_no_w 和数据末端查询补齐缺失分号。
2. 将分位数注释修正为 P50/P75/P90/P95，查询阈值不变。
3. 将 7 天路径筛选中的动态数据末端改为固定截止时间 2020-02-22 23:59:59，保持这份五个月数据上的结果不变。
4. 给 7 天用户表增加显式 DROP TABLE IF EXISTS，与原文其他派生表的重跑方式一致。重跑前须阅读运行说明；本次未执行任何数据库重建。
5. 补充来源、口径、运行顺序和 UTC 执行时间查询。

之前目录中的 stg_* 版本已保存为 [旧路径 SQL](../sql/archive/04_funnel_user_product.stg_before_20260922.sql)，不再与主线混用。

tem_funnel_a 的真实粒度是一行汇总人数，包含 view_cnt/cart_cnt/after_view_purchase_cnt/after_cart_purchase_cnt。历史交接文档把它写成用户级明细表，已在最新进度中纠正。tem_funnel_7d_user 才是一名用户一行，其四个标记列带 _cn 后缀。

[06_funnel_validation.sql](../sql/06_funnel_validation.sql) 为补充验证，不是用户原查询的恢复。覆盖路径唯一性、步骤顺序、来源对应、边界、用户人数、分位数及从 events 出发的独立查询。

[02_import_validation.sql](../sql/02_import_validation.sql) 已根据第 19.3 节的 12 项基准恢复。之前的索引测试内容完整保存在 sql/archive/02_import_validation.index_test_before_20260922.sql。恢复版尚未在 MySQL 中重新执行。

## 全量数据独立复核

执行脚本：[03_validate_funnel_results.py](../python/03_validate_funnel_results.py)。

- 输入：data/processed/clean_data/clean_data.parquet，19,583,742 行；SHA-256 与清洗审计一致。
- 方法：按用户、商品、时间排序，逐组扫描事件并重建路径，再按用户去重；不读取 MySQL 路径表，也不执行归档 SQL。
- 原始事件包含四类；构建漏斗时扫描其中 16,595,883 条浏览、加购和购买事件。
- UTC 开始时间：2026-09-22 09:49:26.476738；结束：09:49:45.267306。
- 共 54 项检查全部通过，包括 12 项导入基准、8 项漏斗人数、耗时及覆盖人数对账、时序、单调性和边界等检查。54 项中包含一项“11 个合成边界控制均通过”的汇总，不把这些控制另算为真实数据记录。
- 运行时间、版本和输出指纹以 run_manifest.json（历史资料：`../data/analysis_output/funnel_20260922/verification/run_manifest.json`） 为准；逐项结果见同目录 validation_checks.csv。

| 口径 | 浏览用户 | 加购用户 | 浏览后购买用户 | 严格购买用户 |
|---|---:|---:|---:|---:|
| 无窗口 | 1,597,754 | 280,595 | 95,198 | 87,330 |
| 7 天 | 1,529,295 | 268,258 | 88,980 | 80,366 |

首次严格转化耗时 P50/P75/P90/P95 分别为 4,338 / 162,335 / 1,123,050 / 2,354,352 秒；1/7/14/30 天覆盖人数分别为 61,520 / 74,608 / 79,119 / 83,403，均与交接记录一致。

此前缺少持久化证据的右截断现已补有 Python 全量结果：总路径 6,899,164；合格路径 6,574,154；排除路径 325,010。起点恰好在截止时刻的路径 1 条，严格购买恰好在第 7 天的路径 1 条，均按含边界规则纳入。

## 归档 SQL 的控制检查

[check_funnel_sql_fixture.py](../python/check_funnel_sql_fixture.py) 使用明确标记的 9 用户合成样本，在内存 SQLite 中适配 MySQL 日期函数、空值比较和除法后执行整理版查询。核对同秒顺序、恰好 7 天、晚一秒、起点右截断、浏览前事件、多商品去重、再次浏览不重启，以及首次完成购买与最短耗时的区别。

该检查验证 SQL 逻辑及实际表名、字段名的连接关系；它不是 MySQL 语法、权限、执行计划或全量运行测试。实际结果及 SQL 指纹记录在 verification/sql_fixture_check.json。

## 结果可以如何引用

- 可以表述：在固定清洗数据和已确定口径下，7 天严格购买用户为 80,366，浏览→严格购买为 5.26%；该结果已获独立全量复核。
- 原代码来源是用户提供，历史结果来源是交接记录；本次独立证据来源是本地 Parquet。
- 不能声称本次重新执行了 Navicat/MySQL，也不能将本次 Python 时间填作历史数据库运行时间。
- 浏览后购买分支不互斥；耗时覆盖率不是正式转化率；无窗口与 7 天分母不同；首次浏览不会重启窗口。完整定义见 [指标字典](metric_dictionary.md)。

## 剩余事项

1. 在原 MySQL 环境按需执行整理版查询和补充验证，保存实际查询结果与运行时间；已有派生表可直接运行对应 SELECT 和只读验证，避免无目的重建。
2. 数据来源页面、许可、双语 README、可视化和发布验收仍待完成；本次没有初始化 Git 或发布网站。
3. 分析主线可进入用户首次观察表和周留存口径确认；14 天敏感性分析不是该阶段的前置条件。
