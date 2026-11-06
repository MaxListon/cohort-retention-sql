-- PART A
WITH base_orders AS (
    SELECT o.order_id, c.customer_unique_id, o.order_purchase_timestamp
    FROM orders o
    JOIN customers c ON c.customer_id = o.customer_id
    WHERE o.order_status = 'delivered'
),
customer_order_sequence AS (
    SELECT
        order_id, customer_unique_id, order_purchase_timestamp,
        ROW_NUMBER() OVER (
            PARTITION BY customer_unique_id ORDER BY order_purchase_timestamp
        ) AS order_number
    FROM base_orders
),
customers_reaching_n AS (
    SELECT order_number, COUNT(DISTINCT customer_unique_id) AS customers_reaching_n
    FROM customer_order_sequence
    GROUP BY order_number
),
n_th_order_retention AS (
    SELECT
        order_number,
        customers_reaching_n,
        FIRST_VALUE(customers_reaching_n) OVER (ORDER BY order_number) AS customers_reaching_order_1,
        ROUND(
            1.0 * customers_reaching_n
            / FIRST_VALUE(customers_reaching_n) OVER (ORDER BY order_number),
            4
        ) AS retention_from_order_1,
        ROUND(
            1.0 * LEAD(customers_reaching_n) OVER (ORDER BY order_number)
            / NULLIF(customers_reaching_n, 0),
            4
        ) AS step_n_to_n1_rate
    FROM customers_reaching_n
)
SELECT order_number, customers_reaching_n, customers_reaching_order_1,
       retention_from_order_1, step_n_to_n1_rate
FROM n_th_order_retention
ORDER BY order_number;
