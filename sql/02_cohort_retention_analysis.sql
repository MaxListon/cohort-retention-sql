-- =====================================================================
-- 02_cohort_retention_analysis.sql
-- Monthly acquisition-cohort retention analysis, built entirely with
-- window functions (no self-joins, no procedural loops).
--
-- Dialect: PostgreSQL (also runs as-is on Snowflake, Redshift, BigQuery
-- with DATE_TRUNC/EXTRACT support; see README for the SQLite variant
-- used to validate this file against the bundled sample data).
--
-- Grain of the output: one row per (cohort_month, period_number), where
--   cohort_month   = the calendar month of a customer's FIRST delivered
--                     order (this is what defines the cohort)
--   period_number  = how many months after the cohort month this row's
--                     activity happened (0 = acquisition month itself,
--                     1 = the following month, etc.)
--
-- Window functions used, and why each one earns its place:
--   MIN()   OVER (PARTITION BY customer)             -> assign each
--           customer to a cohort without a self-join back to their
--           own first order.
--   FIRST_VALUE() OVER (PARTITION BY cohort ORDER BY period)
--           -> pull period-0 cohort size onto every row in that
--           cohort, so retention % is computable with zero joins.
--   LAG()   OVER (PARTITION BY cohort ORDER BY period)
--           -> month-over-month change in retention, for flagging
--           cohorts whose retention is accelerating/decelerating.
--   DENSE_RANK() OVER (ORDER BY cohort_size DESC)
--           -> rank cohorts by acquisition size without a second
--           aggregate query.
-- =====================================================================


-- ---------------------------------------------------------------------
-- Step 0: scope the fact table.
--   - Keep only 'delivered' orders: canceled/unavailable orders never
--     represent fulfilled purchase intent and would inflate cohorts
--     with people who didn't actually receive anything.
--   - Resolve to customer_unique_id, not customer_id (see schema note:
--     customer_id is a surrogate minted per-order in this dataset, so
--     grouping by it would make every "customer" look like a one-time
--     buyer by construction).
-- ---------------------------------------------------------------------
WITH base_orders AS (
    SELECT
        o.order_id,
        c.customer_unique_id,
        o.order_purchase_timestamp
    FROM orders o
    JOIN customers c ON c.customer_id = o.customer_id
    WHERE o.order_status = 'delivered'
),

-- ---------------------------------------------------------------------
-- Step 1: attach each customer's first-ever order date to every one of
-- their order rows. This is the window-function alternative to:
--     SELECT customer_unique_id, MIN(order_purchase_timestamp)
--     FROM base_orders GROUP BY 1   -- then JOIN this back
-- MIN() OVER (PARTITION BY ...) does it in a single pass, no join.
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- Step 2: derive the cohort month, the activity month, and the integer
-- number of months between them ("period_number"). Written out
-- explicitly with EXTRACT(YEAR)/EXTRACT(MONTH) rather than a
-- date-diff helper function, since "how do you compute a month
-- difference by hand" is a frequent interview follow-up.
-- ---------------------------------------------------------------------
cohort_labeled AS (
    SELECT
        customer_unique_id,
        order_id,
        DATE_TRUNC('month', first_order_timestamp)::date        AS cohort_month,
        DATE_TRUNC('month', order_purchase_timestamp)::date      AS order_month,
        (
            (EXTRACT(YEAR  FROM order_purchase_timestamp) - EXTRACT(YEAR  FROM first_order_timestamp)) * 12
          + (EXTRACT(MONTH FROM order_purchase_timestamp) - EXTRACT(MONTH FROM first_order_timestamp))
        )::int AS period_number
    FROM customer_orders_with_cohort
),

-- ---------------------------------------------------------------------
-- Step 3: collapse to one row per (cohort, period, customer) -- a
-- customer who places two orders in the same calendar month should
-- count once as "active", not twice.
-- ---------------------------------------------------------------------
customer_period_activity AS (
    SELECT DISTINCT
        cohort_month,
        period_number,
        customer_unique_id
    FROM cohort_labeled
),

-- ---------------------------------------------------------------------
-- Step 4: count active customers per (cohort, period).
-- ---------------------------------------------------------------------
cohort_period_counts AS (
    SELECT
        cohort_month,
        period_number,
        COUNT(*) AS active_customers
    FROM customer_period_activity
    GROUP BY cohort_month, period_number
),

-- ---------------------------------------------------------------------
-- Step 5: scaffold every (cohort, period) combo that COULD have
-- happened given the data horizon, so that "nobody came back" (0%)
-- is never silently confused with "not enough time has passed yet"
-- (NULL). This is the gotcha that makes the most recent cohorts in a
-- naive cohort table look like they have terrible retention, when
-- really they just haven't had the chance to return yet.
-- ---------------------------------------------------------------------
data_horizon AS (
    SELECT DATE_TRUNC('month', MAX(order_purchase_timestamp))::date AS max_observed_month
    FROM base_orders
),
periods AS (
    SELECT generate_series(0, 11) AS period_number   -- 0..11 months of maturity shown
),
cohort_period_scaffold AS (
    SELECT DISTINCT
        cpc.cohort_month,
        p.period_number
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
        ON c.cohort_month = s.cohort_month
       AND c.period_number = s.period_number
),

-- ---------------------------------------------------------------------
-- Step 6: bring in cohort size via FIRST_VALUE() OVER (...) -- the
-- period-0 active_customers count, broadcast across every row of that
-- cohort's partition -- then compute retention_rate and a
-- period-over-period delta with LAG().
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- Final output: long/"tidy" format -- one row per cohort x period.
-- See 02b_pivot_heatmap.sql for the wide, heatmap-shaped version of
-- this same result (the one you'd paste into a slide).
-- ---------------------------------------------------------------------
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
