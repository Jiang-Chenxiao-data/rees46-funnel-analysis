# 复现与核验

## 运行环境与最小检查

Python 3.13、MySQL 8.0；依赖见根目录 requirements.txt。根目录运行 README 中的两条逻辑检查命令。SQL 样本检查为 SQLite 方言适配，不能作为 MySQL 运行通过的证据。

## 原始事件到漏斗

1. 从 README 中的数据来源取得 `2019-Oct.csv`、`2019-Nov.csv`、`2019-Dec.csv`、`2020-Jan.csv`、`2020-Feb.csv`，置于 `data/raw/`。历史下载日未知；原始数据不随仓库分发。
2. 运行 `python python/01_data_cleaning.py`。五个月合并、全字段完全重复记录去重、删除 brand/category_code、UTC 时间转换，输出 `data/processed/clean_data/clean_data.csv` 与同名 Parquet。该脚本全量内存运行，需要足够内存。不得把不同清洗版本混入固定结果。
3. 运行 `python python/02_parquet_to_mysql.py`，生成 `data/processed/clean_data/clean_data_mysql.csv`。MySQL 导入步骤按 [SQL 说明](../sql/README.md) 在独立空数据库执行，先修改 01 中的 CSV 路径。04/05 会重建派生表。
4. 运行 `python python/03_validate_funnel_results.py --output reproduction_output/funnel`。独立读取固定清洗 Parquet，以状态机重算严格路径；输入文件指纹或基准不符时会停止。不同 Parquet 写入版本可能改变字节指纹，即使逻辑记录相同；不能跳过断言宣称复现原版本。
5. 周留存验证入口为 `python python/05_validate_weekly_retention.py`，读取清洗 Parquet 与 `sql/周cohort留存矩阵.csv`、`sql/周留存核对结果.csv`。该脚本更新原验证目录，运行前先复制仓库或备份输出。
6. 周活跃、回流及分群 SQL 保存在 `sql/weekly/`，为历史查询归档。需检查查询中的数据库、已有表和字段依赖后逐段运行；本轮未连接数据库，不保证可在空库直接连续运行。完整数据库对账仍有待补项。

## 数字的可追溯证据

| 数字 | 文件 |
|---|---|
| 7 天漏斗人数、比例 | [funnel_counts.csv](../data/analysis_output/funnel_20260922/verification/funnel_counts.csv)、[funnel_rates.csv](../data/analysis_output/funnel_20260922/verification/funnel_rates.csv) |
| 同样 19 批次 8.85% → 5.55% | [留存计算记录](../data/analysis_output/weekly_retention_validation_20261020/interpretation_calculations.json) |
| 114,075 → 82,724 及 58.64% 拆解 | [周构成](../data/analysis_output/status_archive_20261026/report_evidence/weekly_user_composition.csv)、[下降拆解](../data/analysis_output/status_archive_20261026/report_evidence/decline_decomposition.csv) |
| 196,795 用户周、64.87% | [回流结果](../data/analysis_output/status_archive_20261026/report_evidence/return_gap_1to5_recomputed.csv) |

原全量漏斗历史检查 54 项、留存 355 项，其运行时间属于历史；本轮只核对发布数字、路径、文件指纹并运行合成边界测试。未重跑约两千万条事件或 MySQL。最终 Word 来自 2026-11-03 的“运营建议与图表修订版”，Markdown 从该文件提取文字、表格及原始内嵌图，不使用 10 月旧报告冒充最终版本。原 Word 附录中的工作目录名是历史来源标记，发布路径以本说明为准。
