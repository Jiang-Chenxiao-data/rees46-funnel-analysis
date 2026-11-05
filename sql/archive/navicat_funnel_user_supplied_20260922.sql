use rees46_funnel_analysis;

#第一次浏览
drop  table if EXISTS tem_first_view;
create table tem_first_view
ENGINE = InnoDB 
AS
select user_id,product_id,min(event_time) as view_time
from events
where event_type ='view'
group by user_id,product_id
ORDER BY
    user_id,
    product_id;
#第一次浏览后加购
drop table if EXISTS tem_view_cart; 
create table tem_view_cart 
ENGINE = InnoDB 
AS
select v.user_id,v.product_id,v.view_time,min(e.event_time) as cart_time
from tem_first_view as v left join events as e on v.user_id=e.user_id and v.product_id=e.product_id and e.event_type='cart' and v.view_time < e.event_time  
group by v.user_id,v.product_id,v.view_time;
#对创建的表格进行验证
SELECT
 (select count(*) from tem_first_view) as row_view,
 (select count(*) from tem_view_cart) as row_cart;
 
 select count(*) as total_paths,sum(cart_time is not null) as reached_cart_paths,sum(cart_time is null) as no_cart_paths
 from tem_view_cart;
 
SELECT COUNT(*) AS invalid_time_paths
FROM tem_view_cart
WHERE cart_time <= view_time;

#浏览后第一次购买
drop table if EXISTS tem_after_view_purchase; 
create table tem_after_view_purchase 
ENGINE = InnoDB 
AS
select vc.user_id,vc.product_id,vc.view_time,vc.cart_time,min(e.event_time) as view_purchase_time
from tem_view_cart as vc left join events as e on vc.user_id=e.user_id and vc.product_id=e.product_id and e.event_type='purchase' and vc.view_time < e.event_time  
group by vc.user_id,vc.product_id,vc.view_time,vc.cart_time;
  
#加购后第一次购买
drop table if EXISTS tem_after_cart_purchase; 
create table tem_after_cart_purchase 
ENGINE = InnoDB 
AS
select vp.user_id,vp.product_id,vp.view_time,vp.cart_time,vp.view_purchase_time,min(e.event_time) as cart_purchase_time
from tem_after_view_purchase as vp left join events as e on vp.user_id=e.user_id and vp.product_id=e.product_id and e.event_type='purchase' and vp.cart_time is not null and vp.cart_time < e.event_time  
group by vp.user_id,vp.product_id,vp.view_time,vp.cart_time,vp.view_purchase_time;

#对创建的表格进行验证
SELECT
 (select count(*) from tem_view_cart) as row_cart,
 (select count(*) from tem_after_view_purchase) as row_view_purchase,
 (select count(*) from tem_after_cart_purchase) as row_cart_purchase;
 
SELECT
    SUM(cart_time IS NOT NULL AND cart_time <= view_time) AS invalid_cart_order,

    SUM(view_purchase_time IS NOT NULL AND view_purchase_time <= view_time) AS invalid_view_purchase_order,

    SUM(cart_purchase_time IS NOT NULL AND (
            cart_time IS NULL OR cart_purchase_time <= cart_time)
    ) AS invalid_cart_purchase_order,

    SUM(cart_purchase_time IS NOT NULL AND (
            view_purchase_time IS NULL OR view_purchase_time > cart_purchase_time
        )
    ) AS invalid_purchase_relation
FROM tem_after_cart_purchase;
 
SELECT
    COUNT(*) AS total_view_paths,
    SUM(cart_time IS NOT NULL) AS reached_cart_paths,
    SUM(view_purchase_time IS NOT NULL) AS purchased_after_view_paths,
    SUM(cart_purchase_time IS NOT NULL) AS strict_purchase_paths
FROM tem_after_cart_purchase;

#确认漏斗步骤
drop table if EXISTS tem_user_product_funnel; 
create table tem_user_product_funnel 
ENGINE = InnoDB 
AS
select user_id,product_id,view_time,cart_time,view_purchase_time,cart_purchase_time,
 1 as reached_view,
 case when cart_time is not null then 1
  else 0 end as reached_cart,
 case when cart_purchase_time is not null then 1
  else 0 end as reached_cart_purchase,
 case when view_purchase_time is not null then 1
  else 0 end as reached_view_purchase
from tem_after_cart_purchase;

#检查是否有重复的用户—商品
select user_id,product_id,count(*) as cnt
from tem_user_product_funnel 
group by user_id,product_id
having cnt>1;

#检查是否出现“没有加购却完成严格购买”的逻辑错误
select user_id,product_id
from tem_user_product_funnel 
where reached_cart=0 and reached_cart_purchase=1;

#统计去重的浏览人数
select count(distinct user_id) as view_cnt from tem_user_product_funnel；
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

select * from tem_funnel_a
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

select* from tem_funnel_no_w


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
##统计时耗的中位数、P25、P75以及P90
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
from events

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
 where  view_time<=(SELECT MAX(event_time) FROM events)-INTERVAL 7 DAY;   
 
# 建立用户表
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