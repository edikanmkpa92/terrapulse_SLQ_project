-- PHASE 6: VIEWS & REPORTING LAYER


CREATE OR REPLACE VIEW vw_monthly_revenue_dashboard AS
SELECT
    YEAR(fo.order_date)         AS revenue_year,
    MONTH(fo.order_date)        AS revenue_month,
    MONTHNAME(fo.order_date)    AS month_name,
    dc.category_name,
    SUM(fo.quantity)            AS units_sold,
    SUM(fo.net_revenue_usd)     AS net_revenue,
    SUM(fo.net_revenue_usd) - SUM(fo.quantity * dp.unit_cost_usd) AS gross_profit
FROM fct_orders fo
JOIN dim_products dp   ON dp.product_id = fo.product_id
JOIN dim_categories dc ON dc.category_id = dp.category_id
GROUP BY YEAR(fo.order_date), MONTH(fo.order_date), MONTHNAME(fo.order_date), dc.category_name;

CREATE OR REPLACE VIEW vw_customer_360 AS
SELECT
    dcu.customer_id,
    dcu.full_name,
    dcu.country,
    COUNT(fo.order_id)                       AS lifetime_order_count,
    COALESCE(SUM(fo.net_revenue_usd), 0)     AS total_spend,
    ROUND(COALESCE(SUM(fo.net_revenue_usd), 0) / NULLIF(COUNT(fo.order_id), 0), 2) AS avg_order_value,
    MAX(fo.order_date)                       AS last_order_date,
    dcu.loyalty_score,
    CASE
        WHEN dcu.loyalty_score >= 800 THEN 'Elite'
        WHEN dcu.loyalty_score >= 600 THEN 'Preferred'
        WHEN dcu.loyalty_score >= 400 THEN 'Standard'
        ELSE 'New'
    END AS loyalty_tier
FROM dim_customers dcu
LEFT JOIN fct_orders fo ON fo.customer_id = dcu.customer_id
GROUP BY dcu.customer_id, dcu.full_name, dcu.country, dcu.loyalty_score;

-- Dead stock = stock on hand and no orders in the last 90 days of data.
-- Returns 0 rows because all 200 products sold in that period.															`
CREATE OR REPLACE VIEW vw_dead_stock_alert AS
SELECT
    dp.product_id,
    dp.product_name,
    dc.category_name,
    dp.warehouse_stock,
    dp.unit_cost_usd,
    ROUND(dp.warehouse_stock * dp.unit_cost_usd, 2) AS capital_tied_up
FROM dim_products dp
JOIN dim_categories dc ON dc.category_id = dp.category_id
WHERE dp.warehouse_stock > 0
  AND NOT EXISTS (
      SELECT 1
      FROM fct_orders fo
      WHERE fo.product_id = dp.product_id
        AND fo.order_date >= DATE_SUB((SELECT MAX(order_date) FROM fct_orders), INTERVAL 90 DAY)
  );
