use rees46_funnel_analysis;

-- 查询用户上一次活跃周
create table tem_prev_active_users
as
select wc.user_id,wc.active_week,wcf.first_week,lag(wc.active_week)over(partition by wc.user_id order by wc.active_week) as prev_active_week
from tem_user_week_cohort_distinct  as wc left join tem_user_week_cohort_first as wcf on wc.user_id=wcf.user_id;

-- 根据用户上一次活跃日期，对用户进行分类
with category_user as (
SELECT
    user_id,
    active_week,
    prev_active_week,
    case when 
    prev_active_week IS NULL
    then 'fresh_user'
    when
    DATEDIFF(active_week, prev_active_week)=7
    THEN
    'consecutive_user'
    when
    DATEDIFF(active_week, prev_active_week)>7
    THEN
    'interval_user'
    end as category_users
FROM tem_prev_active_users
ORDER BY user_id, active_week),

-- 统计各类用户数量
category_sum_users as (
select active_week,count(user_id) as total_user,count(case when category_users='fresh_user' then 1 else null end) as fresh_users_count,
 count(case when category_users='consecutive_user' then 1 else null end) as consecutive_users_count,
 count(case when category_users='interval_user' then 1 else null end ) as interval_users_count
from category_user
group by active_week)

-- 计算各类用户百分比
select active_week,total_user,round(fresh_users_count*100.0/total_user,2) as fresh_user_pct,
 round(consecutive_users_count*100.0/total_user,2) as consecutive_user_pct,
 round(interval_users_count*100.0/total_user,2) as interval_user_pct
from category_sum_users
order by active_week;