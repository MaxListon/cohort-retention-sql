"""
generate_sample_data.py

Generates a synthetic dataset shaped exactly like the Olist Brazilian
E-Commerce dataset (same tables/columns as sql/01_schema.sql) and loads
it into a local SQLite database at output/cohort_demo.db.

WHY SYNTHETIC DATA, NOT THE REAL KAGGLE FILES
-----------------------------------------------
The real Olist dataset requires a Kaggle account/API token to download
and isn't bundled here. Two things also make the raw Olist data a poor
fit for *demonstrating* cohort retention mechanics on its own:
  1. It's a marketplace with a very low repeat-purchase rate (~3% of
     customers ever place a 2nd order), so a real retention heatmap is
     mostly near-zero after period 0 -- true to life, but not great for
     showing off the SQL technique.
  2. It only covers ~25 calendar months, so late cohorts have little
     time to mature (see the "immature cohorts" note in the README).

So this generator creates a dataset with the *same schema and the same
real-world quirks* (the customer_id vs customer_unique_id trap, mixed
order_status values, multi-item orders, multi-installment payments) but
with an injected, heterogeneous repeat-purchase behavior so the
resulting retention table is actually interesting to look at. The SQL
in sql/02_* and sql/03_* is schema-only -- point it at the real Olist
CSVs (loaded into these same table names) and it runs unchanged.
"""

import sqlite3
import random
import datetime as dt
from pathlib import Path

import numpy as np

SEED = 42
random.seed(SEED)
np.random.seed(SEED)

OUT_DIR = Path(__file__).resolve().parent.parent / "output"
OUT_DIR.mkdir(exist_ok=True)
DB_PATH = OUT_DIR / "cohort_demo.db"
SCHEMA_PATH = Path(__file__).resolve().parent.parent / "sql" / "01_schema.sql"

# ---------------------------------------------------------------------
# Acquisition calendar: 24 cohort months, Jan-2017 .. Dec-2018, with a
# growth trend + Nov/Dec seasonality (Black Friday / Christmas), like
# the real Brazilian e-commerce market over this period.
# ---------------------------------------------------------------------
COHORT_MONTHS = [dt.date(2017 + (i // 12), (i % 12) + 1, 1) for i in range(24)]

BASE_SIZE = 260
GROWTH_PER_MONTH = 14
SEASONAL_BONUS = {11: 1.6, 12: 1.8, 6: 1.25}  # Nov, Dec, June (mid-year sale)

STATES = ["SP", "RJ", "MG", "RS", "PR", "BA", "SC", "DF", "GO", "PE"]
CITIES = {
    "SP": "sao paulo", "RJ": "rio de janeiro", "MG": "belo horizonte",
    "RS": "porto alegre", "PR": "curitiba", "BA": "salvador",
    "SC": "florianopolis", "DF": "brasilia", "GO": "goiania", "PE": "recife",
}
PAYMENT_TYPES = ["credit_card", "boleto", "voucher", "debit_card"]
PAYMENT_WEIGHTS = [0.74, 0.19, 0.04, 0.03]
DATA_END = dt.date(2018, 12, 31)  # last day data is observed through


def month_add(d: dt.date, n: int) -> dt.date:
    y = d.year + (d.month - 1 + n) // 12
    m = (d.month - 1 + n) % 12 + 1
    return dt.date(y, m, 1)


def random_ts_in_month(month_start: dt.date) -> dt.datetime:
    nxt = month_add(month_start, 1)
    days_in_month = (nxt - month_start).days
    day_off = random.randint(0, days_in_month - 1)
    seconds_off = random.randint(0, 86399)
    return dt.datetime.combine(month_start, dt.time()) + dt.timedelta(days=day_off, seconds=seconds_off)


# ---------------------------------------------------------------------
# Repeat-purchase model
#   Each customer gets a personal "loyalty" draw from a mixture:
#     - 78% are low-propensity (mostly one-and-done)
#     - 22% are high-propensity (habitual repeat shoppers)
#   Monthly reorder probability decays with months-since-first-purchase
#   (novelty wears off), modulated by the customer's personal factor.
# ---------------------------------------------------------------------
def customer_propensity() -> float:
    if random.random() < 0.22:
        return np.random.beta(5, 8)      # high-propensity segment, mean ~0.38
    return np.random.beta(1.3, 25)       # low-propensity segment, mean ~0.05


def monthly_reorder_prob(base_propensity: float, months_since_first: int) -> float:
    decay = 0.80 ** (months_since_first - 1)
    return min(0.9, base_propensity * decay)


def main():
    customers_rows, orders_rows, items_rows, payments_rows = [], [], [], []

    customer_seq = 0
    order_seq = 0
    product_pool = [f"prod_{i:05d}" for i in range(2000)]
    seller_pool = [f"seller_{i:04d}" for i in range(300)]

    for cohort_idx, cohort_month in enumerate(COHORT_MONTHS):
        bonus = SEASONAL_BONUS.get(cohort_month.month, 1.0)
        n_new = int((BASE_SIZE + GROWTH_PER_MONTH * cohort_idx) * bonus * np.random.uniform(0.9, 1.1))

        for _ in range(n_new):
            customer_seq += 1
            cust_unique_id = f"cu_{customer_seq:06d}"
            state = random.choice(STATES)

            propensity = customer_propensity()

            # first order (defines the cohort)
            months_since = 0
            cur_month = cohort_month
            first = True
            while cur_month <= DATA_END:
                months_since += 1
                if first or random.random() < monthly_reorder_prob(propensity, months_since - 1):
                    order_seq += 1
                    order_id = f"ord_{order_seq:07d}"
                    cust_id = f"c_{order_seq:07d}"  # order-level surrogate (Olist quirk)
                    purchase_ts = random_ts_in_month(cur_month)

                    status_roll = random.random()
                    if status_roll < 0.965:
                        status = "delivered"
                    elif status_roll < 0.985:
                        status = "shipped"
                    elif status_roll < 0.995:
                        status = "canceled"
                    else:
                        status = "unavailable"

                    approved = purchase_ts + dt.timedelta(hours=random.randint(1, 48))
                    carrier = approved + dt.timedelta(days=random.randint(1, 3))
                    delivered = carrier + dt.timedelta(days=random.randint(2, 12))
                    estimated = purchase_ts + dt.timedelta(days=random.randint(10, 25))

                    customers_rows.append((
                        cust_id, cust_unique_id, f"{random.randint(10000,99999):05d}",
                        CITIES[state], state,
                    ))
                    orders_rows.append((
                        order_id, cust_id, status, purchase_ts.isoformat(sep=" "),
                        approved.isoformat(sep=" "),
                        carrier.isoformat(sep=" ") if status != "canceled" else None,
                        delivered.isoformat(sep=" ") if status == "delivered" else None,
                        estimated.isoformat(sep=" "),
                    ))

                    n_items = random.choices([1, 2, 3], weights=[0.65, 0.25, 0.10])[0]
                    order_total = 0.0
                    for item_no in range(1, n_items + 1):
                        price = float(np.round(np.random.lognormal(mean=4.0, sigma=0.6), 2))
                        freight = float(np.round(price * np.random.uniform(0.04, 0.18), 2))
                        items_rows.append((
                            order_id, item_no, random.choice(product_pool),
                            random.choice(seller_pool), price, freight,
                        ))
                        order_total += price + freight

                    pay_type = random.choices(PAYMENT_TYPES, weights=PAYMENT_WEIGHTS)[0]
                    installments = random.choice([1, 2, 3, 4, 6, 10]) if pay_type == "credit_card" else 1
                    payments_rows.append((
                        order_id, 1, pay_type, installments, round(order_total, 2),
                    ))

                    first = False

                cur_month = month_add(cur_month, 1)

    print(f"customers (order-rows): {len(customers_rows):,}")
    print(f"orders:                 {len(orders_rows):,}")
    print(f"order_items:            {len(items_rows):,}")
    print(f"order_payments:         {len(payments_rows):,}")
    print(f"unique customers:       {customer_seq:,}")

    if DB_PATH.exists():
        DB_PATH.unlink()
    conn = sqlite3.connect(DB_PATH)
    conn.executescript(Path(SCHEMA_PATH).read_text())

    conn.executemany(
        "INSERT INTO customers VALUES (?,?,?,?,?)", customers_rows)
    conn.executemany(
        "INSERT INTO orders VALUES (?,?,?,?,?,?,?,?)", orders_rows)
    conn.executemany(
        "INSERT INTO order_items VALUES (?,?,?,?,?,?)", items_rows)
    conn.executemany(
        "INSERT INTO order_payments VALUES (?,?,?,?,?)", payments_rows)
    conn.commit()
    conn.close()
    print(f"\nWrote SQLite DB -> {DB_PATH}")


if __name__ == "__main__":
    main()
