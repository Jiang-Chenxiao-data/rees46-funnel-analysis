use rees46_funnel_analysis;

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


-- 去重后组内购买用户
active_purchase_users as (
select distinct user_id,active_week,event_type
from tem_user_week_cohort
where event_type = 'purchase'),

-- 分类用户购买行为判别表
category_users_purchase as (
select cu.user_id,cu.active_week,cu.category_users,
 case when event_type='purchase'
 then 1
 else 0
 end as purchase_if
 from category_user as cu left join active_purchase_users as apu on cu.user_id=apu.user_id and cu.active_week=apu.active_week
 )
 
 -- 分类用户购买行为规模与占比
 select active_week,category_users,count(user_id) as user_cnt,sum(purchase_if) as purchase_user_cnt,
 round(sum(purchase_if)*100.0/count(user_id),2) as purchase_user_pct
 from category_users_purchase
 group by active_week,category_users
 order by active_week
 

  
 