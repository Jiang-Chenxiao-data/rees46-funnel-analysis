# REES46 用户运营分析

使用 Python 与 MySQL 8.0 分析 2019-10 至 2020-02 的电商行为数据，回答用户在哪里流失、首次访问后何时回访，以及应优先验证哪些运营方案。

## 问题与方法

围绕访问结构 → 同用户同商品严格时序漏斗 → 周 Cohort 留存 → 回流与购买分群建立分析链路。清洗后保留 **19,583,742 条事件、1,639,358 名观察用户**。事件按 UTC 解释；周活跃包括浏览、加购、移出购物车和购买。首次观察用户不等于注册新客。

7 天漏斗先按用户—商品建立路径，再按用户去重；仅保留拥有完整 7 天观察机会的起点。周趋势使用 20 个完整自然周，留存比较统一合格批次；不能观察的留存为 NULL。

## 主要成果

| 发现 | 结果 | 解释边界 |
|---|---|---|
| 7 天浏览→加购→购买 | 1,529,295 → 268,258 → 80,366 人；加购率 17.54%，加购后严格购买率 29.96% | 同用户同商品、严格时序；不是全站订单成交率 |
| 相同 19 个合格批次的留存 | 第 1 周 8.85% → 第 2 周 5.55%，下降 3.30 个百分点 | 首次观察 Cohort；不是第 1 周回访者的流失率 |
| 2019-11-25 与 2019-12-30 起始周活跃 | 114,075 → 82,724，下降 27.48%；首次观察人数减少贡献 58.64% | 指定两周的算术拆解，不是因果归因 |
| 所选 14 周、缺席 1～5 周后回流记录 | 缺席 1～2 周占 64.87% | 196,795 条用户周记录；不是全期去重人数或召回成功率 |

产出严格漏斗、留存、周活跃及分群汇总、10 幅报告图表和运营建议。建议先验证商品筛选与比较、首访后两周运营及短间隔召回；尚无落地收益证据。

## 查看成果

- [最终报告（可浏览）](report/report.md) · [完整 Word 报告](report/report.docx)
- [关键数字来源与复现边界](docs/REPRODUCE.md) · [指标定义](docs/metric_dictionary.md)
- [SQL 执行顺序](sql/README.md) · [简历成果](docs/RESUME.md) · [归档指纹](docs/archive_manifest.json)

![报告图表](figures/figure_01.png)

## 快速开始

使用 Python 3.13；从仓库根目录运行：

```powershell
python -m pip install -r requirements.txt
python python/check_funnel_sql_fixture.py
python python/03_validate_funnel_results.py --self-test
```

以上使用合成边界样本检查逻辑，不需要下载原始数据。全量复现需自行取得同版本五个月数据，按 [完整步骤](docs/REPRODUCE.md) 清洗、导入及核验；数据库整理版 SQL 尚未在本轮重跑，不宣称一键全流程验收。

## 文件结构与来源

`report/` 最终报告；`python/` 清洗与独立核验；`sql/` MySQL 查询；`data/analysis_output/` 汇总结果；`figures/` 最终报告内嵌原图；`docs/` 定义、复现和核验记录。

数据发布方：[REES46 datasets](https://rees46.com/en/datasets)；下载入口：[Kaggle Cosmetics Shop](https://www.kaggle.com/datasets/mkechinov/ecommerce-events-history-in-cosmetics-shop)。数据为观察性记录，无运营干预日志；原始数据和用户级明细不随仓库分发，使用与再分发须遵守来源许可。本报告的多商家平台建议是应用场景迁移，来源描述为单一化妆品网店。
