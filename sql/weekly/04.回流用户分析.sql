use rees46_funnel_analysis;

-- 计算每个用户组内的缺席周数量
with absent_week as (
select user_id,active_week,first_week,prev_active_week,
 round((datediff(active_week,prev_active_week)/7-1),0) as absent_week
from tem_prev_active_users
),

-- 筛选缺席大于等于1周的用户作为回流用户
absent_users as (
select * from absent_week  where absent_week >= 1
),

-- 计算每个分组内所有回流用户数量
sum_absent_users as ( select active_week,count(user_id) as users_sum
from absent_users
group by active_week),

-- 计算每个分组内不同缺席周的回流用户数量
absent_users_cnt as (
select active_week,absent_week,count(user_id) as users_cnt
from absent_users
group by active_week,absent_week
order by active_week),

-- 计算每个分组内不同缺席周的回流用户在组内所有回流用户中的占比
absent_users_cnt_pct as (
select auc.active_week,auc.absent_week,auc.users_cnt,round((auc.users_cnt*100.0/sau.users_sum),2) as users_pct
from absent_users_cnt as auc left join sum_absent_users as sau 
 on auc.active_week=sau.active_week
 ),
-- 确定研究范围：研究2019-11-18 至 2020-02-17的，缺席1-5周的回流用户
 absent_users_limit as (
select * from absent_week  
where absent_week between 1 and 5
 and active_week between '2019-11-18' and '2020-02-17'
),

-- 计算每个分组内所有回流用户数量
sum_absent_users_limit as ( select active_week,count(user_id) as users_sum
from absent_users_limit
group by active_week),

-- 计算每个分组内不同缺席周的回流用户数量
absent_users_cnt_limit as (
select active_week,absent_week,count(user_id) as users_cnt
from absent_users_limit
group by active_week,absent_week
order by active_week)

-- 计算每个分组内不同缺席周的回流用户在组内所有回流用户中的占比
select aucl.active_week,aucl.absent_week,aucl.users_cnt,round((aucl.users_cnt*100.0/saul.users_sum),2) as users_pct,saul.users_sum as users_sum
from absent_users_cnt_limit as aucl left join sum_absent_users_limit as saul 
 on aucl.active_week=saul.active_week

 