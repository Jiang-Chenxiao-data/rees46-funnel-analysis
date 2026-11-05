-- 2026-09-22 归档：以用户提供的 MySQL 实际运行代码为依据。
-- 原文逐字保存在 archive/navicat_funnel_user_supplied_20260922.sql。
-- MySQL 8.0.46；保留 tem_* 普通 InnoDB 表名；事件时间为 UTC。
-- 本次归档未执行 MySQL；既有数据结果已另用全量 Parquet 独立复核。
-- 重跑 DROP/CREATE 会重建已有派生表；当前已有表时按 README 跳过已完成建表段。
-- 原始 events 不在本脚本中修改。固定数据版本：2019-10-01 至 2020-02-29。
-- 先运行 02_import_validation.sql，12 个 *_pass 均为 1 才继续。

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
