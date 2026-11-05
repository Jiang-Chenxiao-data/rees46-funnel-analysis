"""将 Parquet 文件转换成 MySQL 8.0 可以导入的 CSV 文件。"""

from pathlib import Path
import pandas as pd
ROOT = Path(__file__).resolve().parents[1]
(ROOT / "data/processed/clean_data").mkdir(parents=True, exist_ok=True)


# 1. 读取 Parquet 文件
data = pd.read_parquet(
    ROOT / 'data/processed/clean_data/clean_data.parquet'
)


# 2. 将时间转换成 MySQL DATETIME 格式
data["event_time"] = data["event_time"].dt.strftime("%Y-%m-%d %H:%M:%S")


# 3. 保存成 MySQL 可以导入的 CSV 文件
data.to_csv(
    ROOT / 'data/processed/clean_data/clean_data_mysql.csv',
    index=False,
    encoding="utf-8",
    na_rep=r"\N",
)


print("MySQL 数据文件转换完成！")
