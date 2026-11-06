"""
load_real_olist_data.py

Loads the REAL Kaggle Olist CSV files (bundled in data/real_olist_csv/,
originally sourced from the "Brazilian E-Commerce Public Dataset by Olist")
into a SQLite database at output/cohort_real.db, using the exact table
structure defined in sql/01_schema.sql.

This is the genuine dataset: 99,441 customers / orders, 112,650 order
items, 103,886 payments -- these row counts are the well-known signature
of the real Olist data and are how you can verify a copy is legitimate.

Run this, then run the validation/*.sqlite.sql queries against
output/cohort_real.db exactly as they're run against the synthetic
output/cohort_demo.db -- same schema, same queries, no changes needed.
"""

import csv
import sqlite3
from pathlib import Path

PROJECT_DIR = Path(__file__).resolve().parent.parent
CSV_DIR = PROJECT_DIR / "data" / "real_olist_csv"
SCHEMA_PATH = PROJECT_DIR / "sql" / "01_schema.sql"
DB_PATH = PROJECT_DIR / "output" / "cohort_real.db"


def load_csv(cur, path: Path, insert_sql: str, row_fn):
    with open(path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        rows = [row_fn(row) for row in reader]
    cur.executemany(insert_sql, rows)
    return len(rows)


def main():
    if DB_PATH.exists():
        DB_PATH.unlink()
    conn = sqlite3.connect(DB_PATH)
    conn.executescript(SCHEMA_PATH.read_text())
    cur = conn.cursor()

    n = load_csv(
        cur, CSV_DIR / "olist_customers_dataset.csv",
        "INSERT INTO customers VALUES (?,?,?,?,?)",
        lambda r: (
            r["customer_id"], r["customer_unique_id"],
            r["customer_zip_code_prefix"], r["customer_city"], r["customer_state"],
        ),
    )
    print(f"customers:      {n:,}")

    n = load_csv(
        cur, CSV_DIR / "olist_orders_dataset.csv",
        "INSERT INTO orders VALUES (?,?,?,?,?,?,?,?)",
        lambda r: (
            r["order_id"], r["customer_id"], r["order_status"],
            r["order_purchase_timestamp"] or None,
            r["order_approved_at"] or None,
            r["order_delivered_carrier_date"] or None,
            r["order_delivered_customer_date"] or None,
            r["order_estimated_delivery_date"] or None,
        ),
    )
    print(f"orders:         {n:,}")

    # Real file has an extra shipping_limit_date column not in our schema -- dropped on load.
    n = load_csv(
        cur, CSV_DIR / "olist_order_items_dataset.csv",
        "INSERT INTO order_items VALUES (?,?,?,?,?,?)",
        lambda r: (
            r["order_id"], int(r["order_item_id"]), r["product_id"], r["seller_id"],
            float(r["price"]), float(r["freight_value"]),
        ),
    )
    print(f"order_items:    {n:,}")

    n = load_csv(
        cur, CSV_DIR / "olist_order_payments_dataset.csv",
        "INSERT INTO order_payments VALUES (?,?,?,?,?)",
        lambda r: (
            r["order_id"], int(r["payment_sequential"]), r["payment_type"],
            int(r["payment_installments"]), float(r["payment_value"]),
        ),
    )
    print(f"order_payments: {n:,}")

    conn.commit()

    # sanity: unique customers vs order-level customer rows (the customer_id
    # vs customer_unique_id gotcha this project calls out)
    total_rows = cur.execute("SELECT COUNT(*) FROM customers").fetchone()[0]
    unique_people = cur.execute("SELECT COUNT(DISTINCT customer_unique_id) FROM customers").fetchone()[0]
    print(f"\ncustomer_id rows: {total_rows:,}  |  unique customer_unique_id: {unique_people:,}")
    print(f"(difference = {total_rows - unique_people:,} repeat purchases hiding behind the surrogate key)")

    conn.close()
    print(f"\nWrote SQLite DB -> {DB_PATH}")


if __name__ == "__main__":
    main()
