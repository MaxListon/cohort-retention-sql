-- =====================================================================
-- 01_schema.sql
-- Schema for the cohort retention analysis project.
--
-- Mirrors the structure of the real "Brazilian E-Commerce Public Dataset
-- by Olist" (Kaggle: olistbr/brazilian-ecommerce), so these scripts run
-- unmodified against the real CSVs if you download them -- just load
-- them into tables with these names/columns (see README.md "Using the
-- real Olist dataset").
--
-- IMPORTANT OLIST QUIRK (this trips people up constantly):
--   customer_id        -> a surrogate key generated PER ORDER.
--   customer_unique_id -> the actual, stable person.
-- A single shopper who orders 3 times gets 3 different customer_id
-- values but the SAME customer_unique_id. If you build cohorts on
-- customer_id you will get ~0% retention for everyone, because every
-- "customer" only ever appears once by construction. Cohort / retention
-- work on this dataset MUST key off customer_unique_id.
-- =====================================================================

DROP TABLE IF EXISTS order_payments;
DROP TABLE IF EXISTS order_items;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS customers;

CREATE TABLE customers (
    customer_id             VARCHAR(32)  PRIMARY KEY,   -- order-level surrogate (see note above)
    customer_unique_id      VARCHAR(32)  NOT NULL,       -- the real, de-duplicated shopper
    customer_zip_code_prefix VARCHAR(5),
    customer_city           VARCHAR(64),
    customer_state          VARCHAR(2)
);

CREATE TABLE orders (
    order_id                      VARCHAR(32)  PRIMARY KEY,
    customer_id                   VARCHAR(32)  NOT NULL REFERENCES customers(customer_id),
    order_status                  VARCHAR(16)  NOT NULL,   -- delivered / shipped / canceled / unavailable ...
    order_purchase_timestamp      TIMESTAMP    NOT NULL,
    order_approved_at             TIMESTAMP,
    order_delivered_carrier_date  TIMESTAMP,
    order_delivered_customer_date TIMESTAMP,
    order_estimated_delivery_date TIMESTAMP
);

CREATE TABLE order_items (
    order_id         VARCHAR(32) NOT NULL REFERENCES orders(order_id),
    order_item_id    INT         NOT NULL,
    product_id       VARCHAR(32) NOT NULL,
    seller_id        VARCHAR(32) NOT NULL,
    price            NUMERIC(10,2) NOT NULL,
    freight_value    NUMERIC(10,2) NOT NULL,
    PRIMARY KEY (order_id, order_item_id)
);

CREATE TABLE order_payments (
    order_id             VARCHAR(32) NOT NULL REFERENCES orders(order_id),
    payment_sequential   INT         NOT NULL,
    payment_type         VARCHAR(16) NOT NULL,   -- credit_card / boleto / voucher / debit_card
    payment_installments INT         NOT NULL,
    payment_value        NUMERIC(10,2) NOT NULL,
    PRIMARY KEY (order_id, payment_sequential)
);

CREATE INDEX idx_customers_unique_id ON customers(customer_unique_id);
CREATE INDEX idx_orders_customer_id  ON orders(customer_id);
CREATE INDEX idx_orders_purchase_ts  ON orders(order_purchase_timestamp);
