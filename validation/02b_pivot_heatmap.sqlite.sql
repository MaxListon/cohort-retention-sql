WITH RECURSIVE base_orders AS (
    SELECT o.order_id, c.customer_unique_id, o.order_purchase_timestamp
    FROM orders o
    JOIN customers c ON c.customer_id = o.customer_id
    WHERE o.order_status = 'delivered'
),
customer_orders_with_cohort AS (
    SELECT
        order_id, customer_unique_id, order_purchase_timestamp,
        MIN(order_purchase_timestamp) OVER (PARTITION BY customer_unique_id) AS first_order_timestamp
    FROM base_orders
),
cohort_labeled AS (
    SELECT
        customer_unique_id,
        date(first_order_timestamp, 'start of month') AS cohort_month,
        (
            (CAST(strftime('%Y', order_purchase_timestamp) AS INT) - CAST(strftime('%Y', first_order_timestamp) AS INT)) * 12
          + (CAST(strftime('%m', order_purchase_timestamp) AS INT) - CAST(strftime('%m', first_order_timestamp) AS INT))
        ) AS period_number
    FROM customer_orders_with_cohort
),
customer_period_activity AS (
    SELECT DISTINCT cohort_month, period_number, customer_unique_id FROM cohort_labeled
),
cohort_period_counts AS (
    SELECT cohort_month, period_number, COUNT(*) AS active_customers
    FROM customer_period_activity GROUP BY cohort_month, period_number
),
data_horizon AS (
    SELECT date(MAX(order_purchase_timestamp), 'start of month') AS max_observed_month FROM base_orders
),
periods(period_number) AS (
    SELECT 0 UNION ALL SELECT period_number + 1 FROM periods WHERE period_number < 11
),
cohort_period_scaffold AS (
    SELECT DISTINCT cpc.cohort_month, p.period_number
    FROM cohort_period_counts cpc
    CROSS JOIN periods p
    CROSS JOIN data_horizon dh
    WHERE date(cpc.cohort_month, '+' || p.period_number || ' months') <= dh.max_observed_month
),
cohort_period_filled AS (
    SELECT s.cohort_month, s.period_number, COALESCE(c.active_customers, 0) AS active_customers
    FROM cohort_period_scaffold s
    LEFT JOIN cohort_period_counts c
        ON c.cohort_month = s.cohort_month AND c.period_number = s.period_number
),
cohort_retention AS (
    SELECT
        cohort_month, period_number, active_customers,
        FIRST_VALUE(active_customers) OVER (PARTITION BY cohort_month ORDER BY period_number) AS cohort_size,
        ROUND(
            1.0 * active_customers
            / NULLIF(FIRST_VALUE(active_customers) OVER (PARTITION BY cohort_month ORDER BY period_number), 0),
            4
        ) AS retention_rate
    FROM cohort_period_filled
)
SELECT
    cohort_month,
    MAX(cohort_size) AS cohort_size,
    MAX(CASE WHEN period_number = 0  THEN retention_rate END) AS m0,
    MAX(CASE WHEN period_number = 1  THEN retention_rate END) AS m1,
    MAX(CASE WHEN period_number = 2  THEN retention_rate END) AS m2,
    MAX(CASE WHEN period_number = 3  THEN retention_rate END) AS m3,
    MAX(CASE WHEN period_number = 4  THEN retention_rate END) AS m4,
    MAX(CASE WHEN period_number = 5  THEN retention_rate END) AS m5,
    MAX(CASE WHEN period_number = 6  THEN retention_rate END) AS m6,
    MAX(CASE WHEN period_number = 7  THEN retention_rate END) AS m7,
    MAX(CASE WHEN period_number = 8  THEN retention_rate END) AS m8,
    MAX(CASE WHEN period_number = 9  THEN retention_rate END) AS m9,
    MAX(CASE WHEN period_number = 10 THEN retention_rate END) AS m10,
    MAX(CASE WHEN period_number = 11 THEN retention_rate END) AS m11
FROM cohort_retention
GROUP BY cohort_month
ORDER BY cohort_month;
