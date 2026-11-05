use rees46_funnel_analysis;

create table tem_user_week_cohort
ENGINE = InnoDB
AS
WITH

-- 第一步：给每条事件计算所属自然周
event_week AS (
select user_id,event_time,event_type,
 date(event_time) as date_e,
 weekday(date(event_time)) as week_day,
 date_sub(date(event_time),interval weekday(date(event_time)) day) as active_week
 from `events`
 )
select * from event_week;

-- 第二步：每个用户在每个自然周只保留一行
create table tem_user_week_cohort_distinct
ENGINE = InnoDB
AS
select distinct user_id,active_week 
from tem_user_week_cohort;

-- 第三步：识别用户首次出现周
create table tem_user_week_cohort_first
ENGINE = InnoDB
AS
select user_id,min(active_week) as first_week
from tem_user_week_cohort_distinct
group by user_id;

-- 第四步：计算活跃周距离首次出现周的周数
create table tem_user_week_cohort_diff
ENGINE = InnoDB
AS
select td.user_id,td.active_week,tf.first_week,datediff(td.active_week,tf.first_week)/7 as week_diff
from tem_user_week_cohort_distinct as td left join tem_user_week_cohort_first as tf on td.user_id=tf.user_id;

-- 第五步：计算整体每周留存率
 create table  tem_cohort_retention_rate
 ENGINE = InnoDB
 AS
WITH recursive
-- 每个批次最初有多少用户
cohort_size AS (
    SELECT
        first_week,
        COUNT(*) AS count_first
    FROM tem_user_week_cohort_first
    GROUP BY first_week
),
-- 最大完整留存周数
week_limit AS (
    SELECT
        MIN(first_week) AS min_first_week,
        FLOOR(
            (DATEDIFF('2020-02-29', MIN(first_week)) - 6) / 7
        ) AS max_week
    FROM cohort_size
),
-- 要检查的留存周数
retention_weeks AS (
    SELECT 1 AS retention_week from week_limit where max_week >= 1
    UNION ALL
    SELECT retention_week+1 as  retention_week from retention_weeks where retention_week<(select max_week from week_limit)
),
-- 有完整观察时间的“批次＋留存周数”组合
eligible_cohorts AS (
    SELECT
        cs.first_week,
        cs.count_first,
        rw.retention_week
    FROM cohort_size AS cs
    CROSS JOIN retention_weeks AS rw
    WHERE DATE_ADD(
        cs.first_week,
        INTERVAL (6 + 7 * rw.retention_week) DAY
    ) <= '2020-02-29'
),
-- 每个批次在各周实际回来的用户数
retained_all AS (
    SELECT
        first_week,
        week_diff,
        COUNT(user_id) AS retained_users
    FROM tem_user_week_cohort_diff
    GROUP BY first_week, week_diff
),
-- 每个批次的留存率
cohort_retention_rate as (
SELECT
    ec.first_week,
    ec.count_first,
    ec.retention_week,
    case when ra.retained_users is null then 0 else ra.retained_users end as retained_users
FROM eligible_cohorts AS ec
LEFT JOIN retained_all AS ra
    ON ec.first_week = ra.first_week
   AND ec.retention_week = ra.week_diff)
 
 -- 周留存明细表

 select first_week,retention_week,count_first,retained_users, round((retained_users*100/count_first),2) as retention_rate
 from cohort_retention_rate
 order by first_week,retention_week;

select * from tem_cohort_retention_rate

-- 整体的留存率 
select retention_week,sum(count_first) as first_week_users,sum(retained_users) as retention_users,
 round(sum(retained_users)*100/sum(count_first),2) as retention_rate
from tem_cohort_retention_rate
group by retention_week
order by retention_week;

-- 留存率矩阵
select first_week,max(count_first) as cohort_users,
max(case when retention_week=1 then retention_rate end) as retention_rate_1,
max(case when retention_week=2 then retention_rate end) as retention_rate_2,
max(case when retention_week=3 then retention_rate end) as retention_rate_3,
max(case when retention_week=4 then retention_rate end) as retention_rate_4,
max(case when retention_week=5 then retention_rate end) as retention_rate_5,
max(case when retention_week=6 then retention_rate end) as retention_rate_6,
max(case when retention_week=7 then retention_rate end) as retention_rate_7,
max(case when retention_week=8 then retention_rate end) as retention_rate_8,
max(case when retention_week=9 then retention_rate end) as retention_rate_9,
max(case when retention_week=10 then retention_rate end) as retention_rate_10,
max(case when retention_week=11 then retention_rate end) as retention_rate_11,
max(case when retention_week=12 then retention_rate end) as retention_rate_12,
max(case when retention_week=13 then retention_rate end) as retention_rate_13,
max(case when retention_week=14 then retention_rate end) as retention_rate_14,
max(case when retention_week=15 then retention_rate end) as retention_rate_15,
max(case when retention_week=16 then retention_rate end) as retention_rate_16,
max(case when retention_week=17 then retention_rate end) as retention_rate_17,
max(case when retention_week=18 then retention_rate end) as retention_rate_18,
max(case when retention_week=19 then retention_rate end) as retention_rate_19,
max(case when retention_week=20 then retention_rate end) as retention_rate_20
from tem_cohort_retention_rate
group by first_week;
 
 
  
 
