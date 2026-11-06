-- PART B
WITH RECURSIVE base_orders AS (
    SELECT o.order_id, c.customer_unique_id, o.order_purchase_timestamp
    FROM orders o
    JOIN customers c ON c.customer_id = o.customer_id
    WHERE o.order_status = 'delivered'
),
order_revenue AS (
    SELECT order_id, SUM(payment_value) AS order_revenue
    FROM order_payments
    GROUP BY order_id
),
orders_with_revenue AS (
    SELECT
        b.order_id, b.customer_unique_id, b.order_purchase_timestamp,
        COALESCE(r.order_revenue, 0) AS order_revenue
    FROM base_orders b
    LEFT JOIN order_revenue r ON r.order_id = b.order_id
),
customer_orders_with_cohort AS (
    SELECT
        order_id, customer_unique_id, order_purchase_timestamp, order_revenue,
        MIN(order_purchase_timestamp) OVER (PARTITION BY customer_unique_id) AS first_order_timestamp
    FROM orders_with_revenue
),
cohort_labeled AS (
    SELECT
        customer_unique_id,
        order_revenue,
        date(first_order_timestamp, 'start of month') AS cohort_month,
        (
            (CAST(strftime('%Y', order_purchase_timestamp) AS INT) - CAST(strftime('%Y', first_order_timestamp) AS INT)) * 12
          + (CAST(strftime('%m', order_purchase_timestamp) AS INT) - CAST(strftime('%m', first_order_timestamp) AS INT))
        ) AS period_number
    FROM customer_orders_with_cohort
),
cohort_period_revenue AS (
    SELECT
        cohort_month, period_number,
        SUM(order_revenue) AS period_revenue,
        COUNT(DISTINCT customer_unique_id) AS active_customers
    FROM cohort_labeled
    GROUP BY cohort_month, period_number
),
cohort_size AS (
    SELECT
        cohort_month,
        FIRST_VALUE(active_customers) OVER (PARTITION BY cohort_month ORDER BY period_number) AS cohort_size,
        period_number, period_revenue, active_customers
    FROM cohort_period_revenue
),
cohort_ltv AS (
    SELECT
        cohort_month, period_number, cohort_size, period_revenue,
        SUM(period_revenue) OVER (
            PARTITION BY cohort_month ORDER BY period_number
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS cumulative_revenue
    FROM cohort_size
)
SELECT
    cohort_month, period_number, cohort_size,
    ROUND(period_revenue, 2) AS period_revenue,
    ROUND(cumulative_revenue, 2) AS cumulative_revenue,
    ROUND(1.0 * cumulative_revenue / NULLIF(cohort_size, 0), 2) AS cumulative_revenue_per_customer
FROM cohort_ltv
ORDER BY cohort_month, period_number;
