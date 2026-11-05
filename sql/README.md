# MySQL 脚本与漏斗归档

更新：2026-09-22。MySQL 8.0.46；事件时间按 UTC 解释。

04、05 以用户本次提供的实际运行代码为依据，保留 tem_* 普通 InnoDB 表及 *_cn 字段名。[原文备份](archive/navicat_funnel_user_supplied_20260922.sql) 未修改；整理版的必要修正见 [归档记录](../docs/funnel_validation_report.md)。

## 当前数据库已经有派生表时

本次归档没有连接或修改数据库。已有表时优先运行所需 SELECT 及 [06 验证查询](06_funnel_validation.sql)，不必为了归档重跑建表、导入和核心索引。

04、05 中 DROP TABLE / CREATE TABLE 会重建同名派生表。仅在明确需要重建时逐段执行；不要对现有数据库直接整套运行 00–06。02、06 为只读查询；06 第 9 段是从 events 出发的全量独立 SQL，计算量较大，可在需要数据库层复核时运行。

## 从固定清洗数据重现的顺序

| 顺序 | 文件 | 内容及输入输出 | 执行证据 |
|---:|---|---|---|
| 0 | 00_schema.sql | 创建数据库及 events 明细表 | 历史已执行 |
| 1 | 01_load_data.sql | 把本地 MySQL CSV 导入空 events | 历史已执行；不可向已装载表重复导入 |
| 2 | 02_import_validation.sql | 核对 12 项行数、事件、时间、会话和价格基准 | 历史验收通过；本次恢复版未在 MySQL 重跑 |
| 3 | 03_indexes.sql | 两个用户/用户—商品索引 | 历史已创建；现有库跳过 |
| 4 | 04_funnel_user_product.sql | events → 首次浏览、加购、两个购买分支、路径标记 | 按用户实际代码归档；整理版未在 MySQL 重跑 |
| 5 | 05_funnel_metrics.sql | 无窗口汇总、首次严格耗时、分位数、覆盖率、7 天路径与用户表 | 按用户实际代码归档；整理版未在 MySQL 重跑 |
| 6 | 06_funnel_validation.sql | 只读核对粒度、时序、边界、人数与分位数 | 本次补充；待原 MySQL 环境运行 |

进入步骤 4 前，02 的 12 个 *_pass 必须全部为 1。数据版本固定为 2019-10-01 至 2020-02-29，清洗后 19,583,742 行；7 天起点截止 2020-02-22 23:59:59。新增数据应建立新版本。

## 表名和粒度

| 表 | 粒度/用途 |
|---|---|
| events | 一条清洗后事件 |
| tem_first_view | 每个有浏览的用户—商品一行；不是用户首次观察表 |
| tem_view_cart | 相同用户—商品粒度，补第一次浏览后加购 |
| tem_after_view_purchase | 补浏览后第一次购买 |
| tem_after_cart_purchase | 补加购后第一次购买 |
| tem_user_product_funnel | 同粒度路径和无窗口步骤标记 |
| tem_funnel_a | **一行**无窗口四步去重人数 |
| tem_funnel_no_w | **一行**无窗口人数及四位小数比例 |
| tem_user_first_strict | 每名已严格转化用户一行；time_step 单位为秒 |
| tem_funnel_7d_path | 每条拥有完整 7 天观察机会的用户—商品路径一行 |
| tem_funnel_7d_user | 每名合格用户一行；四个 reached_*_7d_cn 标记 |

tem_ 只是名称前缀，这些都是普通 InnoDB 表，跨 Navicat 会话保留。原 stg_* 版本仅在 archive/ 中保存为历史资料，不与当前主线混用。

05 中的分位数、覆盖率和 7 天比率以查询结果返回，没有另建结果表。需在 Navicat 将相应结果导出 CSV，并记录脚本输出的 UTC 起止时间。

## 已归档结果与独立复核

结果目录（历史资料：`../data/analysis_output/funnel_20260922/README.md`） 已保存交接历史值、本次 Python 全量重算 CSV、54 项检查及运行清单。全部已记录漏斗人数、耗时分位数和覆盖人数一致。该证据独立于 MySQL 路径表，不代表整理版 SQL 已在 MySQL 执行。

从项目根目录运行：

~~~powershell
python python/03_validate_funnel_results.py
python python/check_funnel_sql_fixture.py
~~~

依赖见 [requirements-funnel-validation.txt](../python/requirements-funnel-validation.txt)，实际版本见运行清单。前者只读完整 Parquet；后者使用内存 SQLite 和合成数据对归档 SQL 作方言适配后的逻辑检查，不是 MySQL 运行验收。

后续数据库导出建议保存到 data/analysis_output/funnel_20260922/mysql_exports/UTC运行时间/，注明数据版本、MySQL 版本、SQL 文件指纹、开始/结束 UTC 时间；不要将 Python CSV 改名成数据库导出。

## 导入与环境约定

- 01 中的 CSV 绝对路径须改为本机实际路径。
- 导入前确认目标 events 为空，local_infile 已按需要配置；出错先核对表内行数，不能直接重试导入。
- 在同一连接中紧接导入运行 SHOW WARNINGS。
- 03 中两个已执行索引不重复创建；事件—时间候选索引保持注释，按将来的查询计划评估。
- DATETIME 不含时区信息；本项目统一把其值解释为 UTC。
- 原始数据与 CSV/Parquet 大文件不随代码发布；零价、负价仍保留为行为事件。

口径见 [事件字典](../docs/event_dictionary.md) 与 [指标字典](../docs/metric_dictionary.md)。归档目录的 .sql 文件用于保留原文和旧版证据，不在正常运行顺序中。
