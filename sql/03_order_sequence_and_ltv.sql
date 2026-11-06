-- =====================================================================
-- 03_order_sequence_and_ltv.sql
-- Two bonus analyses on top of the same base data, both leaning on
-- window functions:
--
--   PART A — "N-th order" retention (order-sequence cohorts)
--     Instead of calendar months, the cohort axis here is simply
--     "how many orders has this customer placed" (1st, 2nd, 3rd...).
--     This is the Instacart-style framing, and it's where interviewers
--     usually go next: "what % of people who placed a 2nd order go on
--     to place a 3rd?" i.e. step N -> N+1 retention.
--
--   PART B — Cohort revenue / LTV curves
--     Cumulative revenue per acquisition cohort over time, using a
--     running SUM() OVER a frame -- the standard way to build a
--     cumulative-LTV-by-cohort chart.
--
-- Dialect: PostgreSQL (see README for the SQLite twin used to
-- validate this against the bundled sample data).
-- =====================================================================


-- =====================================================================
-- PART A: N-th order retention (order-sequence cohorts)
-- =====================================================================

WITH base_orders AS (
    SELECT
        o.order_id,
        c.customer_unique_id,
        o.order_purchase_timestamp
    FROM orders o
    JOIN customers c ON c.customer_id = o.customer_id
    WHERE o.order_status = 'delivered'
),

-- ROW_NUMBER() OVER gives each customer's orders a 1, 2, 3... sequence
-- by purchase time -- this *is* the cohort key for this analysis.
customer_order_sequence AS (
    SELECT
        order_id,
        customer_unique_id,
        order_purchase_timestamp,
        ROW_NUMBER() OVER (
            PARTITION BY customer_unique_id
            ORDER BY order_purchase_timestamp
        ) AS order_number
    FROM base_orders
),

-- How many distinct customers reached each order_number at all.
-- customers_reaching_n(1) = everybody (by definition everyone has an
-- order #1); customers_reaching_n(2) = everyone who came back once;
-- and so on. Strictly decreasing as order_number increases.
customers_reaching_n AS (
    SELECT
        order_number,
        COUNT(DISTINCT customer_unique_id) AS customers_reaching_n
    FROM customer_order_sequence
    GROUP BY order_number
),

-- retention_from_order_1 = cumulative % of the original customer base
-- still placing an Nth order at all (classic repeat-purchase curve).
-- step_n_to_n1_rate = of customers who reached order N, what % of
-- THEM went on to reach order N+1 -- the literal "N to N+1" retention
-- number, computed with LEAD() so each row answers "...and then?"
-- without a self-join.
n_th_order_retention AS (
    SELECT
        order_number,
        customers_reaching_n,
        FIRST_VALUE(customers_reaching_n) OVER (
            ORDER BY order_number
        ) AS customers_reaching_order_1,
        ROUND(
            customers_reaching_n::numeric
            / FIRST_VALUE(customers_reaching_n) OVER (ORDER BY order_number),
            4
        ) AS retention_from_order_1,
        ROUND(
            LEAD(customers_reaching_n) OVER (ORDER BY order_number)::numeric
            / NULLIF(customers_reaching_n, 0),
            4
        ) AS step_n_to_n1_rate
    FROM customers_reaching_n
)

SELECT
    order_number,
    customers_reaching_n,
    customers_reaching_order_1,
    retention_from_order_1,   -- e.g. 0.21 = 21% of all customers eventually place this many orders
    step_n_to_n1_rate         -- e.g. 0.55 = of those who reached order N, 55% went on to order N+1
FROM n_th_order_retention
ORDER BY order_number;


-- =====================================================================
-- PART B: cohort revenue / LTV curves
-- =====================================================================

WITH base_orders AS (
    SELECT
        o.order_id,
        c.customer_unique_id,
        o.order_purchase_timestamp
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
        b.order_id,
        b.customer_unique_id,
        b.order_purchase_timestamp,
        COALESCE(r.order_revenue, 0) AS order_revenue
    FROM base_orders b
    LEFT JOIN order_revenue r ON r.order_id = b.order_id
),

customer_orders_with_cohort AS (
    SELECT
        order_id,
        customer_unique_id,
        order_purchase_timestamp,
        order_revenue,
        MIN(order_purchase_timestamp) OVER (
            PARTITION BY customer_unique_id
        ) AS first_order_timestamp
    FROM orders_with_revenue
),

cohort_labeled AS (
    SELECT
        customer_unique_id,
        order_revenue,
        DATE_TRUNC('month', first_order_timestamp)::date AS cohort_month,
        (
            (EXTRACT(YEAR  FROM order_purchase_timestamp) - EXTRACT(YEAR  FROM first_order_timestamp)) * 12
          + (EXTRACT(MONTH FROM order_purchase_timestamp) - EXTRACT(MONTH FROM first_order_timestamp))
        )::int AS period_number
    FROM customer_orders_with_cohort
),

-- revenue actually recognized by each cohort, in each period
cohort_period_revenue AS (
    SELECT
        cohort_month,
        period_number,
        SUM(order_revenue)                      AS period_revenue,
        COUNT(DISTINCT customer_unique_id)       AS active_customers
    FROM cohort_labeled
    GROUP BY cohort_month, period_number
),

-- cohort_size (period-0 headcount), reused to express LTV per
-- acquired customer, not just per *active* customer.
cohort_size AS (
    SELECT
        cohort_month,
        FIRST_VALUE(active_customers) OVER (
            PARTITION BY cohort_month ORDER BY period_number
        ) AS cohort_size,
        period_number,
        period_revenue,
        active_customers
    FROM cohort_period_revenue
),

-- the running SUM() OVER a frame is the whole trick here: cumulative
-- revenue through period N, per cohort, in one pass.
cohort_ltv AS (
    SELECT
        cohort_month,
        period_number,
        cohort_size,
        period_revenue,
        SUM(period_revenue) OVER (
            PARTITION BY cohort_month
            ORDER BY period_number
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS cumulative_revenue
    FROM cohort_size
)

SELECT
    cohort_month,
    period_number,
    cohort_size,
    ROUND(period_revenue, 2)                                   AS period_revenue,
    ROUND(cumulative_revenue, 2)                                AS cumulative_revenue,
    ROUND(cumulative_revenue / NULLIF(cohort_size, 0), 2)       AS cumulative_revenue_per_customer  -- the LTV curve
FROM cohort_ltv
ORDER BY cohort_month, period_number;
