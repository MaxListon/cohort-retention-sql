-- SQLite dialect twin of sql/02_cohort_retention_analysis.sql, used only
-- to execute against the bundled sample DB and prove the logic is
-- correct (see README "Why two dialects"). The CTE structure and every
-- window function are identical; only date-math syntax differs:
--   DATE_TRUNC('month', ts)         -> date(ts, 'start of month')
--   EXTRACT(YEAR/MONTH FROM ts)     -> CAST(strftime('%Y'/'%m', ts) AS INT)
--   generate_series(0,11)           -> recursive CTE
--   cohort_month + 'n months'::interval -> date(cohort_month, '+n months')

WITH RECURSIVE base_orders AS (
    SELECT
        o.order_id,
        c.customer_unique_id,
        o.order_purchase_timestamp
    FROM orders o
    JOIN customers c ON c.customer_id = o.customer_id
    WHERE o.order_status = 'delivered'
),
customer_orders_with_cohort AS (
    SELECT
        order_id,
        customer_unique_id,
        order_purchase_timestamp,
        MIN(order_purchase_timestamp) OVER (
            PARTITION BY customer_unique_id
        ) AS first_order_timestamp
    FROM base_orders
),
cohort_labeled AS (
    SELECT
        customer_unique_id,
        order_id,
        date(first_order_timestamp, 'start of month')        AS cohort_month,
        date(order_purchase_timestamp, 'start of month')     AS order_month,
        (
            (CAST(strftime('%Y', order_purchase_timestamp) AS INT) - CAST(strftime('%Y', first_order_timestamp) AS INT)) * 12
          + (CAST(strftime('%m', order_purchase_timestamp) AS INT) - CAST(strftime('%m', first_order_timestamp) AS INT))
        ) AS period_number
    FROM customer_orders_with_cohort
),
customer_period_activity AS (
    SELECT DISTINCT cohort_month, period_number, customer_unique_id
    FROM cohort_labeled
),
cohort_period_counts AS (
    SELECT cohort_month, period_number, COUNT(*) AS active_customers
    FROM customer_period_activity
    GROUP BY cohort_month, period_number
),
data_horizon AS (
    SELECT date(MAX(order_purchase_timestamp), 'start of month') AS max_observed_month
    FROM base_orders
),
periods(period_number) AS (
    SELECT 0
    UNION ALL
    SELECT period_number + 1 FROM periods WHERE period_number < 11
),
cohort_period_scaffold AS (
    SELECT DISTINCT cpc.cohort_month, p.period_number
    FROM cohort_period_counts cpc
    CROSS JOIN periods p
    CROSS JOIN data_horizon dh
    WHERE date(cpc.cohort_month, '+' || p.period_number || ' months') <= dh.max_observed_month
),
cohort_period_filled AS (
    SELECT
        s.cohort_month,
        s.period_number,
        COALESCE(c.active_customers, 0) AS active_customers
    FROM cohort_period_scaffold s
    LEFT JOIN cohort_period_counts c
        ON c.cohort_month = s.cohort_month AND c.period_number = s.period_number
),
cohort_retention AS (
    SELECT
        cohort_month,
        period_number,
        active_customers,
        FIRST_VALUE(active_customers) OVER (
            PARTITION BY cohort_month ORDER BY period_number
        ) AS cohort_size,
        ROUND(
            1.0 * active_customers
            / NULLIF(FIRST_VALUE(active_customers) OVER (
                  PARTITION BY cohort_month ORDER BY period_number
              ), 0),
            4
        ) AS retention_rate
    FROM cohort_period_filled
),
cohort_retention_with_trend AS (
    SELECT
        cohort_month,
        period_number,
        active_customers,
        cohort_size,
        retention_rate,
        LAG(retention_rate) OVER (
            PARTITION BY cohort_month ORDER BY period_number
        ) AS prior_period_retention,
        retention_rate - LAG(retention_rate) OVER (
            PARTITION BY cohort_month ORDER BY period_number
        ) AS mom_retention_change,
        DENSE_RANK() OVER (
            ORDER BY cohort_size DESC
        ) AS cohort_size_rank
    FROM cohort_retention
)
SELECT
    cohort_month,
    period_number,
    cohort_size,
    active_customers,
    retention_rate,
    mom_retention_change,
    cohort_size_rank
FROM cohort_retention_with_trend
ORDER BY cohort_month, period_number;
