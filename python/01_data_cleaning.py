"""电商用户行为数据清洗。"""

from pathlib import Path
import pandas as pd
ROOT = Path(__file__).resolve().parents[1]
(ROOT / "data/processed/clean_data").mkdir(parents=True, exist_ok=True)


# 1. 读取五个月的数据
data_oct = pd.read_csv(
    ROOT / 'data/raw/2019-Oct.csv'
)

data_nov = pd.read_csv(
    ROOT / 'data/raw/2019-Nov.csv'
)

data_dec = pd.read_csv(
    ROOT / 'data/raw/2019-Dec.csv'
)

data_jan = pd.read_csv(
    ROOT / 'data/raw/2020-Jan.csv'
)

data_feb = pd.read_csv(
    ROOT / 'data/raw/2020-Feb.csv'
)


# 2. 将五个月的数据合并在一起
data = pd.concat(
    [data_oct, data_nov, data_dec, data_jan, data_feb],
    ignore_index=True,
)


# 3. 删除完全重复的数据
data = data.drop_duplicates()


# 4. 删除 brand 和 category_code 两列
data = data.drop(columns=["brand", "category_code"])


# 5. 修改字段格式
data["event_time"] = pd.to_datetime(data["event_time"], utc=True)
data["price"] = data["price"].astype(float)


# 6. 将清洗后的数据保存为 CSV 文件
data.to_csv(
    ROOT / 'data/processed/clean_data/clean_data.csv',
    index=False,
)


print("数据清洗完成！")

# Persist the same cleaned rows for the independent validators.
data.to_parquet(ROOT / "data/processed/clean_data/clean_data.parquet", index=False)
