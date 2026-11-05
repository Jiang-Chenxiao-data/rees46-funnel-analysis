-- 2026-09-22 归档：以用户提供的 MySQL 实际运行代码为依据。
-- 原文逐字保存在 archive/navicat_funnel_user_supplied_20260922.sql。
-- MySQL 8.0.46；保留 tem_* 普通 InnoDB 表名；事件时间为 UTC。
-- 本次归档未执行 MySQL；既有数据结果已另用全量 Parquet 独立复核。
-- 重跑 DROP/CREATE 会重建已有派生表；当前已有表时按 README 跳过已完成建表段。
-- 原始 events 不在本脚本中修改。固定数据版本：2019-10-01 至 2020-02-29。
-- 先运行 02_import_validation.sql，12 个 *_pass 均为 1 才继续。

-- 内容：无窗口汇总、首次严格转化耗时、分位数、候选窗口覆盖率、正式 7 天漏斗。
-- tem_funnel_a / tem_funnel_no_w 各一行；tem_user_first_strict 每用户一行。
-- tem_funnel_7d_user 保留实际 *_cn 字段名；不重命名为另一套表。
-- 原文缺失/全角分号已修正，分位数注释已更正；详情见 docs/funnel_validation_report.md。
-- 所有结果查询可在 Navicat 导出 CSV；导出时一并记录下方 UTC 执行时间。
USE rees46_funnel_analysis;
SELECT UTC_TIMESTAMP(6) AS metrics_started_at_utc;

#统计去重的浏览人数
select count(distinct user_id) as view_cnt from tem_user_product_funnel;
#统计去重后的每个步骤人数
drop table if exists tem_funnel_a;
create table tem_funnel_a
engine=innodb
AS 
select count(distinct user_id) as view_cnt,
 count(distinct if(cart_time is not null,user_id,null)) as cart_cnt,
 count(distinct if(view_purchase_time is not null,user_id,null)) as after_view_purchase_cnt,
 count(distinct if(cart_purchase_time is not null,user_id,null)) as after_cart_purchase_cnt
from tem_user_product_funnel;

select * from tem_funnel_a;
#无窗口期漏斗分析结果
drop table if exists tem_funnel_no_w;
create table tem_funnel_no_w
engine=innodb
AS 
select  view_cnt,
    cart_cnt,
    after_view_purchase_cnt,
    after_cart_purchase_cnt,round((cart_cnt/view_cnt),4) as cart_view,
 round((after_view_purchase_cnt/view_cnt),4) as any_purchase_view,
 round((after_cart_purchase_cnt/cart_cnt),4) as strict_purchase_cart,
 round((after_cart_purchase_cnt/view_cnt),4) as strict_purchase_view
from tem_funnel_a;

select* from tem_funnel_no_w;


#分析严格转化耗时
##建立“每个用户第一次完成严格转化”的耗时明细表

drop table if exists tem_user_first_strict;
create table tem_user_first_strict
ENGINE = InnoDB
AS
with tem_time_rank as (
select user_id,product_id,view_time,cart_time,cart_purchase_time,row_number()over(partition by user_id order by cart_purchase_time,view_time,cart_time) as rk
from tem_after_cart_purchase
where cart_time is not null and cart_purchase_time is not null )
select user_id,product_id,view_time,cart_time,cart_purchase_time,timestampdiff(second,view_time,cart_purchase_time) as time_step
from tem_time_rank
where rk=1;

select * from tem_user_first_strict limit 15;

##检验表格
SELECT
    COUNT(*) AS row_cnt,
    COUNT(DISTINCT user_id) AS user_cnt
FROM tem_user_first_strict;

select count(*) as cnt_01 FROM tem_user_first_strict
where time_step is null or time_step<0;

select max(time_step) as max_step,min(time_step) as min_step
from tem_user_first_strict;
##统计时耗的中位数（P50）、P75、P90以及P95
WITH t AS (
    SELECT
        time_step,
        CUME_DIST() OVER (ORDER BY time_step) AS cd
    FROM tem_user_first_strict
)
SELECT
    MIN(IF(cd >= 0.50, time_step, NULL)) AS median,
    MIN(IF(cd >= 0.75, time_step, NULL)) AS p75,
    MIN(IF(cd >= 0.90, time_step, NULL)) AS p90,
    MIN(IF(cd >= 0.95, time_step, NULL)) AS p95
FROM t;
##统计时耗为1天、7天、14天、30天完成转化的比例
SELECT
    COUNT(*) AS total_converted_users,

    SUM(IF(time_step <= 1 * 24 * 60 * 60, 1, 0)) AS within_1day_users,
    ROUND(
        SUM(IF(time_step <= 1 * 24 * 60 * 60, 1, 0))
        / COUNT(*) * 100,
        2
    ) AS within_1day_pct,

    SUM(IF(time_step <= 7 * 24 * 60 * 60, 1, 0)) AS within_7days_users,
    ROUND(
        SUM(IF(time_step <= 7 * 24 * 60 * 60, 1, 0))
        / COUNT(*) * 100,
        2
    ) AS within_7days_pct,

    SUM(IF(time_step <= 14 * 24 * 60 * 60, 1, 0)) AS within_14days_users,
    ROUND(
        SUM(IF(time_step <= 14 * 24 * 60 * 60, 1, 0))
        / COUNT(*) * 100,
        2
    ) AS within_14days_pct,

    SUM(IF(time_step <= 30 * 24 * 60 * 60, 1, 0)) AS within_30days_users,
    ROUND(
        SUM(IF(time_step <= 30 * 24 * 60 * 60, 1, 0))
        / COUNT(*) * 100,
        2
    ) AS within_30days_pct

FROM tem_user_first_strict;#选定7天作为窗口期

#确认数据末端和7天截止时间
select max(event_time) as date_end_time,date_sub(max(event_time),INTERVAL 7 DAY) as date_sub_time
from events;

#创建具有完整7天观察窗口的用户-商品表
drop table if exists tem_funnel_7d_path;
create table tem_funnel_7d_path
engine=InnoDB
as 
select user_id,product_id,view_time,cart_time,view_purchase_time,cart_purchase_time,1 as reached_view_7d,
 case WHEN
  cart_time is not NULL
  and cart_time<=view_time +Interval 7 DAY
  then 1
  else 0
  end as reached_cart_7d, 
  
  case WHEN
  view_purchase_time is not NULL
  and view_purchase_time<=view_time + Interval 7 DAY
  then 1
  else 0
  end as reached_view_purchase_7d,  
  
  case WHEN
  cart_purchase_time is not NULL
  and cart_purchase_time<=view_time + Interval 7 DAY
  then 1
  else 0
  end as reached_strict_purchase_7d
 from tem_after_cart_purchase
 where view_time <= '2020-02-22 23:59:59'; -- 归档固定边界；原文使用 MAX(event_time)-7 DAY   
 
# 建立用户表
-- 归档补充：与其他派生表一致，明确重跑时重建本表。
DROP TABLE IF EXISTS tem_funnel_7d_user;
CREATE TABLE tem_funnel_7d_user
ENGINE = InnoDB
AS
SELECT
    user_id,
    MAX(reached_view_7d) AS reached_view_7d_cn,
    MAX(reached_cart_7d) AS reached_cart_7d_cn,
    MAX(reached_view_purchase_7d) AS reached_view_purchase_7d_cn,
    MAX(reached_strict_purchase_7d) AS reached_strict_purchase_7d_cn
FROM tem_funnel_7d_path
GROUP BY user_id; 
#验收用户表
SELECT
    COUNT(*) AS row_count,
    COUNT(DISTINCT user_id) AS user_count,
    SUM(reached_view_7d_cn) AS view_users,
    SUM(reached_cart_7d_cn) AS cart_users,
    SUM(reached_view_purchase_7d_cn) AS view_purchase_users,
    SUM(reached_strict_purchase_7d_cn) AS strict_purchase_users,
    SUM(
        reached_strict_purchase_7d_cn = 1
        AND reached_cart_7d_cn = 0
    ) AS invalid_users
FROM tem_funnel_7d_user;  

#比率
with counts as 
( 
 select count(*) as view_users,SUM(reached_cart_7d_cn) AS cart_users,SUM(reached_strict_purchase_7d_cn) AS strict_purchase_users
    FROM tem_funnel_7d_user
)
select view_users,cart_users,strict_purchase_users,round(cart_users*100.0/nullif(view_users,0),2)  AS view_to_cart_pct,
    ROUND(strict_purchase_users * 100.0 / NULLIF(cart_users, 0), 2)
        AS cart_to_strict_purchase_pct,
    ROUND(strict_purchase_users * 100.0 / NULLIF(view_users, 0), 2)
        AS view_to_strict_purchase_pct
FROM counts;

SELECT UTC_TIMESTAMP(6) AS metrics_completed_at_utc;
