-- PHASE 3: ETL CLEANING PIPELINE (staging -> production)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 3.1 Currencies, Categories & Products
-- ----------------------------------------------------------------------------

INSERT INTO dim_currencies (currency_code, currency_name, rate_to_usd)
SELECT DISTINCT
    UPPER(TRIM(currency_code_raw)),
    TRIM(currency_name_raw),
    CAST(TRIM(rate_to_usd_raw) AS DECIMAL(15,6))
FROM stg_fx_rates;

SELECT COUNT(*) FROM dim_currencies;

INSERT INTO dim_categories (category_name)
SELECT DISTINCT TRIM(category_name_raw)
FROM stg_products
WHERE category_name_raw IS NOT NULL AND TRIM(category_name_raw) <> '';

SELECT COUNT(*) FROM dim_categories;

INSERT INTO dim_products (product_id, sku_code, product_name, category_id,
                           unit_cost_usd, retail_price_usd, warehouse_stock)
SELECT
    CAST(p.product_id AS UNSIGNED),
    TRIM(p.sku_code_raw),
    TRIM(p.product_name_raw),
    c.category_id,
    CAST(TRIM(p.unit_cost_raw) AS DECIMAL(15,2)),
    CAST(TRIM(p.retail_price_raw) AS DECIMAL(15,2)),
    CAST(COALESCE(NULLIF(TRIM(p.warehouse_stock_raw), ''), '0') AS UNSIGNED)
FROM stg_products p
JOIN dim_categories c ON c.category_name = TRIM(p.category_name_raw);

SELECT COUNT(*) FROM dim_products;

-- ----------------------------------------------------------------------------
-- 3.2 Customer Standardization
-- ----------------------------------------------------------------------------

INSERT INTO dim_customers (customer_id, first_name, last_name, full_name,
                            email, phone_clean, country, city,
                            loyalty_score, registration_date)
SELECT
    CAST(customer_id AS UNSIGNED),
    CONCAT(UPPER(LEFT(TRIM(first_name_raw), 1)), LOWER(SUBSTRING(TRIM(first_name_raw), 2))) AS first_name,
    CASE
        WHEN last_name_raw IS NULL OR TRIM(last_name_raw) = '' THEN NULL
        ELSE CONCAT(UPPER(LEFT(TRIM(last_name_raw), 1)), LOWER(SUBSTRING(TRIM(last_name_raw), 2)))
    END AS last_name,
    CONCAT_WS(' ',
        CONCAT(UPPER(LEFT(TRIM(first_name_raw), 1)), LOWER(SUBSTRING(TRIM(first_name_raw), 2))),
        CASE WHEN last_name_raw IS NULL OR TRIM(last_name_raw) = '' THEN NULL
             ELSE CONCAT(UPPER(LEFT(TRIM(last_name_raw), 1)), LOWER(SUBSTRING(TRIM(last_name_raw), 2)))
        END
    ) AS full_name,
    NULLIF(TRIM(email_raw), '') AS email,
    NULLIF(TRIM(phone_raw), '') AS phone_clean,
    COALESCE(NULLIF(TRIM(country_raw), ''), 'Unknown') AS country,
    NULLIF(TRIM(city_raw), '') AS city,
    CAST(COALESCE(NULLIF(TRIM(loyalty_score_raw), ''), '500') AS UNSIGNED) AS loyalty_score,
    -- Normalize 4 date formats: YYYY-MM-DD / MM/DD/YYYY / DD-Mon-YYYY / DD/MM/YYYY
    CASE
        WHEN registration_date_raw REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
            THEN STR_TO_DATE(registration_date_raw, '%Y-%m-%d')
        WHEN registration_date_raw REGEXP '^[0-9]{2}-[A-Za-z]{3}-[0-9]{4}$'
            THEN STR_TO_DATE(registration_date_raw, '%d-%b-%Y')
        WHEN registration_date_raw REGEXP '^[0-9]{2}/[0-9]{2}/[0-9]{4}$'
            THEN CASE
                     -- If the first segment can't be a month (>12), it must be DD/MM/YYYY
                     WHEN CAST(SUBSTRING_INDEX(registration_date_raw, '/', 1) AS UNSIGNED) > 12
                         THEN STR_TO_DATE(registration_date_raw, '%d/%m/%Y')
                     ELSE STR_TO_DATE(registration_date_raw, '%m/%d/%Y')
                 END
        ELSE NULL
    END AS registration_date
FROM stg_customers;

-- ----------------------------------------------------------------------------
-- 3.3 Order Status & Multi-Currency Conversion
-- ----------------------------------------------------------------------------

INSERT INTO fct_orders (order_id, customer_id, product_id, currency_code, order_date,
                         order_status, quantity, unit_price_native, unit_price_usd,
                         gross_amount_usd, discount_pct, discount_amount_usd,
                         shipping_fee_usd, net_revenue_usd)
SELECT
    CAST(o.order_id AS UNSIGNED),
    CAST(o.customer_id AS UNSIGNED),
    CAST(o.product_id AS UNSIGNED),
    UPPER(TRIM(o.currency_code_raw)),
    CASE
        WHEN o.order_date_raw REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
            THEN STR_TO_DATE(o.order_date_raw, '%Y-%m-%d')
        WHEN o.order_date_raw REGEXP '^[0-9]{2}-[A-Za-z]{3}-[0-9]{4}$'
            THEN STR_TO_DATE(o.order_date_raw, '%d-%b-%Y')
        WHEN o.order_date_raw REGEXP '^[0-9]{2}/[0-9]{2}/[0-9]{4}$'
            THEN CASE
                     WHEN CAST(SUBSTRING_INDEX(o.order_date_raw, '/', 1) AS UNSIGNED) > 12
                         THEN STR_TO_DATE(o.order_date_raw, '%d/%m/%Y')
                     ELSE STR_TO_DATE(o.order_date_raw, '%m/%d/%Y')
                 END
        ELSE NULL
    END AS order_date,
    CONCAT(UPPER(LEFT(TRIM(o.order_status_raw), 1)), LOWER(SUBSTRING(TRIM(o.order_status_raw), 2))) AS order_status,
    CAST(o.quantity_raw AS UNSIGNED) AS quantity,
    CAST(o.unit_price_raw AS DECIMAL(15,2)) AS unit_price_native,
    ROUND(CAST(o.unit_price_raw AS DECIMAL(15,6)) * fx.rate_to_usd_raw, 2) AS unit_price_usd,
    ROUND(CAST(o.unit_price_raw AS DECIMAL(15,6)) * fx.rate_to_usd_raw * CAST(o.quantity_raw AS UNSIGNED), 2) AS gross_amount_usd,
    CAST(COALESCE(NULLIF(TRIM(o.discount_pct_raw), ''), '0') AS DECIMAL(5,2)) AS discount_pct,
    ROUND(
        CAST(o.unit_price_raw AS DECIMAL(15,6)) * fx.rate_to_usd_raw * CAST(o.quantity_raw AS UNSIGNED)
        * (CAST(COALESCE(NULLIF(TRIM(o.discount_pct_raw), ''), '0') AS DECIMAL(5,2)) / 100), 2
    ) AS discount_amount_usd,
    CAST(COALESCE(NULLIF(TRIM(o.shipping_fee_raw), ''), '0') AS DECIMAL(15,2)) AS shipping_fee_usd,
    ROUND(
        (CAST(o.unit_price_raw AS DECIMAL(15,6)) * fx.rate_to_usd_raw * CAST(o.quantity_raw AS UNSIGNED))
        - (CAST(o.unit_price_raw AS DECIMAL(15,6)) * fx.rate_to_usd_raw * CAST(o.quantity_raw AS UNSIGNED)
           * (CAST(COALESCE(NULLIF(TRIM(o.discount_pct_raw), ''), '0') AS DECIMAL(5,2)) / 100))
        + CAST(COALESCE(NULLIF(TRIM(o.shipping_fee_raw), ''), '0') AS DECIMAL(15,6)), 2
    ) AS net_revenue_usd
FROM stg_orders o
JOIN stg_fx_rates fx ON UPPER(TRIM(fx.currency_code_raw)) = UPPER(TRIM(o.currency_code_raw));

SELECT COUNT(*)
FROM stg_orders o
JOIN stg_fx_rates fx ON UPPER(TRIM(fx.currency_code_raw))=UPPER(TRIM(o.currency_code_raw));

SELECT COUNT(*) FROM fct_orders;

SELECT COUNT(*)
FROM dim_products;

SELECT COUNT(*) FROM stg_orders o
LEFT JOIN dim_customers c ON CAST(O.customer_id AS UNSIGNED) = C.customer_id
WHERE C.customer_id IS NULL;

SELECT DISTINCT currency_code_raw FROM stg_orders;

SELECT COUNT(*) FROM stg_orders o
LEFT JOIN dim_products p ON CAST(o.product_id AS UNSIGNED) = p.product_id
WHERE p.product_id IS NULL;

SELECT COUNT(*) FROM stg_orders o
LEFT JOIN dim_currencies c ON UPPER(TRIM(O.currency_code_raw)) = c.currency_code
WHERE c.currency_code IS NULL;

SELECT * FROM dim_currencies;

SELECT DISTINCT currency_code_raw
FROM stg_fx_rates;




-- 3.4 Logistics Cleaning
-- ----------------------------------------------------------------------------

INSERT INTO fct_logistics (order_id, carrier_name, tracking_number, ship_date,
                            shipping_lead_days, warehouse_origin)
SELECT
    CAST(l.order_id AS UNSIGNED),
    CASE
        WHEN l.carrier_name_raw IS NULL OR TRIM(l.carrier_name_raw) = '' THEN 'Unassigned'
        ELSE CONCAT(UPPER(LEFT(TRIM(l.carrier_name_raw), 1)), LOWER(SUBSTRING(TRIM(l.carrier_name_raw), 2)))
    END AS carrier_name,
    NULLIF(TRIM(l.tracking_number_raw), '') AS tracking_number,
    CASE
        WHEN l.ship_date_raw REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
            THEN STR_TO_DATE(l.ship_date_raw, '%Y-%m-%d')
        WHEN l.ship_date_raw REGEXP '^[0-9]{2}-[A-Za-z]{3}-[0-9]{4}$'
            THEN STR_TO_DATE(l.ship_date_raw, '%d-%b-%Y')
        WHEN l.ship_date_raw REGEXP '^[0-9]{2}/[0-9]{2}/[0-9]{4}$'
            THEN CASE
                     WHEN CAST(SUBSTRING_INDEX(l.ship_date_raw, '/', 1) AS UNSIGNED) > 12
                         THEN STR_TO_DATE(l.ship_date_raw, '%d/%m/%Y')
                     ELSE STR_TO_DATE(l.ship_date_raw, '%m/%d/%Y')
                 END
        ELSE NULL
    END AS ship_date,
    DATEDIFF(
        CASE
            WHEN l.ship_date_raw REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
                THEN STR_TO_DATE(l.ship_date_raw, '%Y-%m-%d')
            WHEN l.ship_date_raw REGEXP '^[0-9]{2}-[A-Za-z]{3}-[0-9]{4}$'
                THEN STR_TO_DATE(l.ship_date_raw, '%d-%b-%Y')
            WHEN l.ship_date_raw REGEXP '^[0-9]{2}/[0-9]{2}/[0-9]{4}$'
                THEN CASE
                         WHEN CAST(SUBSTRING_INDEX(l.ship_date_raw, '/', 1) AS UNSIGNED) > 12
                             THEN STR_TO_DATE(l.ship_date_raw, '%d/%m/%Y')
                         ELSE STR_TO_DATE(l.ship_date_raw, '%m/%d/%Y')
                     END
            ELSE NULL
        END,
        fo.order_date
    ) AS shipping_lead_days,
    NULLIF(TRIM(l.warehouse_origin_raw), '') AS warehouse_origin
FROM stg_logistics l
JOIN fct_orders fo ON fo.order_id = CAST(l.order_id AS UNSIGNED);
