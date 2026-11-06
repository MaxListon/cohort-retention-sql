-- =====================================================================
-- 02b_pivot_heatmap.sql
-- Wide/pivoted version of 02_cohort_retention_analysis.sql: one row
-- per cohort, one column per period_number (0-11), values = retention
-- rate. This is the classic cohort "heatmap" table.
--
-- Built on top of the same CTEs as 02_*.sql via conditional
-- aggregation (MAX(CASE WHEN period_number = n THEN retention_rate
-- END)). Pivoting is the one step here that is NOT a window function
-- -- window functions compute per-row values across a partition, they
-- don't reshape rows into columns -- so conditional aggregation (or
-- your warehouse's native PIVOT/CROSSTAB, e.g. FILTER in Postgres) is
-- the right tool for this last step.
-- =====================================================================

WITH base_orders AS (
    SELECT o.order_id, c.customer_unique_id, o.order_purchase_timestamp
    FROM orders o
    JOIN customers c ON c.customer_id = o.customer_id
    WHERE o.order_status = 'delivered'
),
customer_orders_with_cohort AS (
    SELECT
        order_id,
        customer_unique_id,
        order_purchase_timestamp,
        MIN(order_purchase_timestamp) OVER (PARTITION BY customer_unique_id) AS first_order_timestamp
    FROM base_orders
),
cohort_labeled AS (
    SELECT
        customer_unique_id,
        DATE_TRUNC('month', first_order_timestamp)::date AS cohort_month,
        (
            (EXTRACT(YEAR  FROM order_purchase_timestamp) - EXTRACT(YEAR  FROM first_order_timestamp)) * 12
          + (EXTRACT(MONTH FROM order_purchase_timestamp) - EXTRACT(MONTH FROM first_order_timestamp))
        )::int AS period_number
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
    SELECT DATE_TRUNC('month', MAX(order_purchase_timestamp))::date AS max_observed_month
    FROM base_orders
),
periods AS (
    SELECT generate_series(0, 11) AS period_number
),
cohort_period_scaffold AS (
    SELECT DISTINCT cpc.cohort_month, p.period_number
    FROM cohort_period_counts cpc
    CROSS JOIN periods p
    CROSS JOIN data_horizon dh
    WHERE cpc.cohort_month + (p.period_number || ' months')::interval <= dh.max_observed_month
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
            active_customers::numeric
            / NULLIF(FIRST_VALUE(active_customers) OVER (PARTITION BY cohort_month ORDER BY period_number), 0),
            4
        ) AS retention_rate
    FROM cohort_period_filled
)

SELECT
    cohort_month,
    MAX(cohort_size)                                              AS cohort_size,
    MAX(CASE WHEN period_number = 0  THEN retention_rate END)     AS m0,
    MAX(CASE WHEN period_number = 1  THEN retention_rate END)     AS m1,
    MAX(CASE WHEN period_number = 2  THEN retention_rate END)     AS m2,
    MAX(CASE WHEN period_number = 3  THEN retention_rate END)     AS m3,
    MAX(CASE WHEN period_number = 4  THEN retention_rate END)     AS m4,
    MAX(CASE WHEN period_number = 5  THEN retention_rate END)     AS m5,
    MAX(CASE WHEN period_number = 6  THEN retention_rate END)     AS m6,
    MAX(CASE WHEN period_number = 7  THEN retention_rate END)     AS m7,
    MAX(CASE WHEN period_number = 8  THEN retention_rate END)     AS m8,
    MAX(CASE WHEN period_number = 9  THEN retention_rate END)     AS m9,
    MAX(CASE WHEN period_number = 10 THEN retention_rate END)     AS m10,
    MAX(CASE WHEN period_number = 11 THEN retention_rate END)     AS m11
FROM cohort_retention
GROUP BY cohort_month
ORDER BY cohort_month;
