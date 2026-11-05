"""读取 MySQL 导出的 CSV，绘制周 Cohort 留存热力图。

运行示例（在项目根目录）：
    python python/04_plot_weekly_retention_heatmap.py

依赖：pandas、numpy、matplotlib。
CSV 中 11.21 已表示 11.21%，无需再次乘以 100。
"""
from pathlib import Path
import argparse
import json
import hashlib

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.colors import LinearSegmentedColormap, Normalize
from matplotlib import font_manager
from matplotlib.transforms import blended_transform_factory
import numpy as np
import pandas as pd

PROJECT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description="从留存矩阵 CSV 生成热力图")
    parser.add_argument("--input", type=Path, default=PROJECT / "sql/周cohort留存矩阵.csv")
    parser.add_argument("--output-dir", type=Path, default=PROJECT / "outputs/weekly_retention")
    parser.add_argument("--data-end", default="2020-02-29")
    args = parser.parse_args()

    # 1. 读取 CSV，并把日/月/年的日期转换为真正的日期。
    data = pd.read_csv(args.input, encoding="utf-8-sig")
    rate_cols = sorted(
        [c for c in data.columns if c.startswith("retention_rate_")],
        key=lambda c: int(c.rsplit("_", 1)[1]),
    )
    if not rate_cols:
        raise ValueError("没有找到 retention_rate_N 留存率列")
    data["first_week"] = pd.to_datetime(data["first_week"], dayfirst=True, errors="raise")
    data["cohort_users"] = pd.to_numeric(data["cohort_users"], errors="raise")
    data = data.sort_values("first_week").reset_index(drop=True)
    values = data[rate_cols].apply(pd.to_numeric, errors="raise").to_numpy(float)
    weeks = np.array([int(c.rsplit("_", 1)[1]) for c in rate_cols])

    # 2. 检查粒度、数值范围及观察时间。空值保留，绝不填成 0。
    if data["first_week"].duplicated().any():
        raise ValueError("同一个首次出现批次存在多行")
    if (data["first_week"].dt.weekday != 0).any():
        raise ValueError("首次出现周标签必须是周一")
    if (data["cohort_users"] <= 0).any():
        raise ValueError("批次人数必须大于 0")
    if not np.all(data["cohort_users"] == np.floor(data["cohort_users"])):
        raise ValueError("批次人数应为整数")
    finite = np.isfinite(values)
    if not finite.any() or np.any((values[finite] < 0) | (values[finite] > 100)):
        raise ValueError("留存率应在 0～100 之间，且至少存在一个有效值")
    target_sundays = (
        data["first_week"].to_numpy()[:, None]
        + (7 * weeks + 6).astype("timedelta64[D]")
    )
    eligible = target_sundays <= np.datetime64(args.data_end)
    if not np.array_equal(finite, eligible):
        raise ValueError("空值位置与目标周完整性条件不一致，请先检查导出数据或截止日期")

    # 3. 设置中文字体和统一色阶，只给留存率着色。
    preferred_fonts = ["SimHei", "Microsoft YaHei", "Noto Sans CJK SC"]
    installed = {f.name for f in font_manager.fontManager.ttflist}
    chosen = next((f for f in preferred_fonts if f in installed), None)
    if chosen is None:
        raise RuntimeError("缺少中文字体，请安装黑体或修改 preferred_fonts")
    plt.rcParams.update({
        "font.family": chosen, "axes.unicode_minus": False,
        "svg.fonttype": "path", "pdf.fonttype": 42,
    })
    cmap = LinearSegmentedColormap.from_list(
        "retention_blue", ["#f2f7fc", "#acd0e8", "#397eb8", "#114776"]
    )
    cmap.set_bad("white")
    vmax = float(np.ceil(np.nanmax(values)))
    norm = Normalize(vmin=0, vmax=vmax)

    # 4. 绘制矩阵。行是批次，列是首次出现后的周数。
    fig = plt.figure(figsize=(18.5, 12), facecolor="white")
    ax = fig.add_axes([0.205, 0.185, 0.70, 0.65])
    image = ax.imshow(np.ma.masked_invalid(values), cmap=cmap, norm=norm, aspect="auto")
    ax.set_xticks(range(len(weeks)), labels=[str(w) for w in weeks])
    ax.xaxis.tick_top()
    ax.xaxis.set_label_position("top")
    ax.set_xlabel("首次出现后的第 N 周", fontsize=12, labelpad=14)
    ax.tick_params(axis="x", length=0, pad=7, labelsize=10)
    ax.set_yticks([])
    ax.set_xticks(np.arange(-0.5, len(weeks), 1), minor=True)
    ax.set_yticks(np.arange(-0.5, len(data), 1), minor=True)
    ax.grid(which="minor", color="#e5eaf0", linewidth=0.65)
    ax.tick_params(which="minor", bottom=False, left=False, top=False)
    for spine in ax.spines.values():
        spine.set_visible(False)

    trans = blended_transform_factory(ax.transAxes, ax.transData)
    for row, record in data.iterrows():
        ax.text(-0.255, row, record["first_week"].strftime("%Y-%m-%d"),
                transform=trans, ha="left", va="center", fontsize=10, clip_on=False)
        ax.text(-0.025, row, f'{int(record["cohort_users"]):,}',
                transform=trans, ha="right", va="center", fontsize=10, clip_on=False)
        for col in range(len(weeks)):
            if finite[row, col]:
                rgba = cmap(norm(values[row, col]))
                luminance = 0.2126 * rgba[0] + 0.7152 * rgba[1] + 0.0722 * rgba[2]
                color = "white" if luminance < 0.53 else "#172d40"
                ax.text(col, row, f"{values[row, col]:.2f}",
                        ha="center", va="center", color=color, fontsize=8.3)

    ax.text(-0.255, 1.035, "首次观察批次", transform=ax.transAxes,
            fontsize=11, ha="left", va="bottom")
    ax.text(-0.025, 1.035, "批次人数", transform=ax.transAxes,
            fontsize=11, ha="right", va="bottom")
    fig.text(0.0265, 0.95, "周 Cohort 活跃留存热力图", fontsize=23, weight="bold")
    fig.text(0.0265, 0.912,
             f"REES46 电商行为数据  |  2019-10-01 至 {args.data_end}（UTC）"
             f"  |  {len(data)} 个可观察批次  |  单位：%",
             fontsize=12, color="#465566")
    cax = fig.add_axes([0.925, 0.185, 0.012, 0.65])
    bar = fig.colorbar(image, cax=cax)
    bar.set_label("留存率（%）", fontsize=11, labelpad=10)
    bar.outline.set_visible(False)
    bar.ax.tick_params(labelsize=10, length=0)

    fig.text(0.0265, 0.118,
             "读图：每行追踪同一批用户；每列比较相同回访阶段。"
             "色阶从 0 起，颜色越深表示留存率越高。",
             fontsize=11, color="#354557")
    fig.text(0.0265, 0.083,
             "口径：浏览、加购、移出购物车或购买任一行为均算活跃；不要求连续每周回访。"
             "空白表示目标周观察不足，0.00 才表示完整观察后无人回访。",
             fontsize=10, color="#465566")
    fig.text(0.0265, 0.048,
             "说明：首批仅覆盖 2019-10-01 至 10-06；首次观察不等于新注册。"
             f"来源：{args.input.name}（MySQL 查询导出，保留原始百分数）。",
             fontsize=10, color="#465566")

    # 5. 保存分享图片、矢量图以及核对记录，便于以后重新生成。
    args.output_dir.mkdir(parents=True, exist_ok=True)
    for suffix in ["png", "svg"]:
        fig.savefig(args.output_dir / f"weekly_cohort_retention_heatmap.{suffix}",
                    dpi=220, facecolor="white")
    plt.close(fig)
    summary = {
        "source": str(args.input.resolve()),
        "source_sha256": hashlib.sha256(args.input.read_bytes()).hexdigest(),
        "data_end_date": args.data_end,
        "scope": "用户导出的 MySQL 留存率矩阵；未重跑原始事件计算",
        "cohorts": len(data), "retention_weeks": weeks.tolist(),
        "valid_cells": int(finite.sum()), "unobservable_cells": int((~finite).sum()),
        "eligible_users_week_1": int(data.loc[finite[:, 0], "cohort_users"].sum()),
        "min_rate_pct": float(np.nanmin(values)), "max_rate_pct": float(np.nanmax(values)),
        "missing_mask_matches_complete_target_weeks": True,
        "note": "该导出包含四舍五入后的批次百分比，无精确回访人数，不从此表反推精确整体留存率。",
    }
    (args.output_dir / "source_check.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(json.dumps(summary, ensure_ascii=True, indent=2))


if __name__ == "__main__":
    main()

