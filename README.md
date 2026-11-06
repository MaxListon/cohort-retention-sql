# Cohort retention analysis — e-commerce (Olist-shaped)

A self-contained cohort retention project built entirely with hand-written SQL
window functions, on a dataset shaped exactly like the real **Olist Brazilian
E-Commerce** dataset (same tables, same columns, same gotchas). No ORM, no
BI tool, no dbt — just the queries an analyst would actually write and defend
in an interview.

## What's in here

```
sql/
  01_schema.sql                     -- DDL (customers, orders, order_items, order_payments)
  02_cohort_retention_analysis.sql  -- core monthly cohort retention table (long format)
  02b_pivot_heatmap.sql             -- same analysis, pivoted to the classic heatmap shape
  03_order_sequence_and_ltv.sql     -- bonus: n-th order retention + cohort LTV curves
data/
  real_olist_csv/                   -- the genuine Kaggle Olist CSVs (customers, orders,
                                        order_items, order_payments)
  load_real_olist_data.py           -- loads the real CSVs above into output/cohort_real.db
  generate_sample_data.py           -- builds a ~17k-order synthetic dataset for a
                                        more visually interesting heatmap demo
validation/
  *.sqlite.sql                      -- SQLite-dialect twins of the sql/ queries, used to
                                        prove the logic against both bundled databases
output/
  cohort_real.db                    -- real data loaded into SQLite
  cohort_demo.db                    -- synthetic data loaded into SQLite
  real/*.csv                        -- query results on the real data, already run
  *.csv                             -- query results on the synthetic data, already run
```

The SQL in `sql/` is written for **PostgreSQL** (also runs unmodified on
Snowflake, Redshift, and BigQuery — they all support standard window
functions and `DATE_TRUNC`/`EXTRACT`). SQLite doesn't support `DATE_TRUNC`,
`EXTRACT`, or `generate_series`, so `validation/` holds date-math-only twins
of the same queries, used purely to execute and sanity-check the logic
against the bundled sample data. **The CTE structure and every window
function are identical between the two** — only the date arithmetic differs.

## Two datasets are bundled: real and synthetic

This project ships with **both**:

1. **The real Kaggle Olist dataset** (`data/real_olist_csv/`) — the actual
   `olist_customers_dataset.csv`, `olist_orders_dataset.csv`,
   `olist_order_items_dataset.csv`, and `olist_order_payments_dataset.csv`,
   with the well-known real row counts (99,441 orders, 112,650 order
   items, 103,886 payments). `data/load_real_olist_data.py` loads these
   into `output/cohort_real.db`, and every query in `sql/` and
   `validation/` runs against it unmodified.
2. **A synthetic dataset** (`data/generate_sample_data.py` →
   `output/cohort_demo.db`) shaped identically but with an injected
   repeat-purchase pattern, used only because the real data's retention
   is genuinely tiny (see below) and a synthetic heatmap is a better way
   to *see* what the SQL is doing at a glance.

**Why both matter**: the real Olist data is a marketplace with a true
repeat-purchase rate of about **3%** — of 93,358 customers who placed a
first order, only 2,801 ever placed a second. Month-1 retention across
cohorts runs **0.2%–0.8%**, not the double-digit percentages you'd see
in a subscription product. That's a real, correctly-computed finding —
not a bug — and it's one of the more interesting things to talk through
in an interview: a single-vendor marketplace where third-party sellers
fulfill directly has structurally different retention dynamics than a
SaaS or app-based product. The synthetic dataset exists purely so the
heatmap has visible texture to demonstrate the SQL technique; the real
numbers are the ones to actually cite.

Point `sql/*.sql` (the Postgres-dialect files) at any database loaded from
`sql/01_schema.sql` — real or synthetic — and every query runs unmodified.

## The gotcha that matters most: `customer_id` vs `customer_unique_id`

This is the single most important thing to know about this dataset, real or
synthetic, and it's a great thing to bring up in an interview:

> In Olist, `customer_id` is a **surrogate key minted per order** — a
> customer who orders three times gets three different `customer_id`
> values. `customer_unique_id` is the actual, stable person. If you build
> cohorts on `customer_id`, every "customer" looks like a one-time buyer by
> construction and retention is ~0% for everyone. **All cohort work here
> keys off `customer_unique_id`.**

## Methodology

**Cohort definition**: a customer's cohort is the calendar month of their
first **delivered** order (`order_status = 'delivered'` only — canceled and
undeliverable orders aren't fulfilled purchase intent and would inflate
cohort membership with people who never actually received anything).

**Period number**: integer months between the cohort month and the month of
a later order (0 = acquisition month itself, 1 = the next month, etc.),
computed explicitly from `EXTRACT(YEAR ...)` / `EXTRACT(MONTH ...)` rather
than a date-diff helper — this is a common interview follow-up ("how would
you compute a month difference by hand?").

**Immature cohorts**: the most recent cohorts haven't had 11 months to
mature yet. The pipeline scaffolds every (cohort, period) pair that *could*
exist given the data's max observed date, so "hasn't had the chance to
return yet" renders as a blank cell, never a misleading `0%`. This is a
classic mistake in naive cohort queries — without the scaffold step, recent
cohorts look artificially bad.

## Window functions used, and why each one earns its place

| Function | Used for | Why not a self-join |
|---|---|---|
| `MIN() OVER (PARTITION BY customer)` | Find each customer's first order date | Avoids a `GROUP BY` + join back to the order table just to label every row with its own cohort |
| `FIRST_VALUE() OVER (PARTITION BY cohort ORDER BY period)` | Broadcast period-0 cohort size onto every row of that cohort | Makes `retention_rate = active / cohort_size` a zero-join row-level computation |
| `LAG() OVER (PARTITION BY cohort ORDER BY period)` | Month-over-month change in retention | Flags accelerating/decelerating cohorts without a second pass |
| `DENSE_RANK() OVER (ORDER BY cohort_size DESC)` | Rank cohorts by acquisition size | One-query ranking, no separate aggregate subquery |
| `ROW_NUMBER() OVER (PARTITION BY customer ORDER BY order_date)` | Assign each customer's orders a 1st/2nd/3rd... sequence | This *is* the cohort key for the bonus "n-th order" analysis |
| `LEAD() OVER (ORDER BY order_number)` | "Of people who reached order N, what % reached order N+1" | The literal step-N-to-N+1 retention number, no self-join |
| `SUM() OVER (... ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` | Cumulative revenue per cohort over time | The standard running-total pattern for an LTV curve |

Pivoting the long-format table into the wide heatmap (`02b_pivot_heatmap.sql`)
uses **conditional aggregation** (`MAX(CASE WHEN period_number = n THEN ...
END)`), not a window function — window functions compute per-row values
across a partition, they don't reshape rows into columns, so this is the
right tool for that one step.

## Results

### On the real Olist data (`output/real/`)

- 21 usable monthly cohorts (Oct 2016 – Aug 2018; two single-customer
  cohorts at the start of the dataset are excluded from the heatmap
  visual as noise, though they remain in the raw CSV output), 96,096
  unique customers (`customer_unique_id`), 99,441 order-level rows
- Month-1 retention runs **0.2%–0.8%** across cohorts — tiny, and
  genuinely so: this is a real finding about a marketplace model, not an
  error in the query
- `output/real/03a_nth_order_retention.csv`: of 93,358 customers who
  placed a 1st order, only **3.0%** (2,801) placed a 2nd —
  `step_n_to_n1_rate` for 1→2. Of those who reached a 2nd order, **8.1%**
  went on to a 3rd; of those who reached a 3rd, **20.6%** went on to a
  4th — retention conditional on reaching a given order number climbs
  steeply, meaning the handful of customers who come back a second time
  are disproportionately likely to become repeat buyers
- `output/real/03b_ltv_curves.csv`: cumulative revenue per cohort grows
  almost entirely from month-0 spend; the long tail of later months adds
  only a few percent more, consistent with the low repeat-purchase rate

### On the synthetic data (`output/`)

- 24 monthly cohorts, Jan 2017 – Dec 2018, ~12,000 unique customers
- Month-1 retention generally runs 8–15% across cohorts, decaying to
  1–3% by month 6+ — deliberately higher than the real data so the
  heatmap has visible texture; see "Two datasets are bundled" above
- `03_order_sequence_and_ltv.sql` Part A: of customers who place a 2nd
  order, ~37% go on to place a 3rd (`step_n_to_n1_rate` from 2 → 3)
- Part B: cumulative revenue per acquired customer roughly doubles from
  month-0 spend to month-11 cumulative spend, driven by a small habitual-
  repeat-buyer segment

Full output is in `output/02_cohort_retention_long.csv`,
`output/02b_pivot_heatmap.csv`, `output/03a_nth_order_retention.csv`, and
`output/03b_ltv_curves.csv` (synthetic), and the matching files under
`output/real/` (real Olist data).

## How to run it

```bash
# --- Real data ---
# 1. Load the bundled real Olist CSVs (writes output/cohort_real.db)
python3 data/load_real_olist_data.py

# 2. Run the SQLite-dialect queries against it:
python3 - <<'EOF'
import sqlite3
conn = sqlite3.connect("output/cohort_real.db")
sql = open("validation/02_cohort_retention_analysis.sqlite.sql").read()
for row in conn.execute(sql).fetchall()[:20]:
    print(row)
EOF

# --- Synthetic data ---
# 1. Generate the sample dataset (writes output/cohort_demo.db)
python3 data/generate_sample_data.py

# 2. Same validation queries, swap the db path to output/cohort_demo.db
```

To run the **Postgres-dialect** `sql/*.sql` files (the ones to actually
show off — they're what you'd write at a real job), load either CSV set
into Postgres/Snowflake/Redshift/BigQuery using `sql/01_schema.sql`, then
run `sql/02_cohort_retention_analysis.sql`, `sql/02b_pivot_heatmap.sql`,
and `sql/03_order_sequence_and_ltv.sql` unmodified.

## Where the real data came from

The real CSVs bundled in `data/real_olist_csv/` are the genuine "Brazilian
E-Commerce Public Dataset by Olist," originally published on Kaggle
(`olistbr/brazilian-ecommerce`) and verified here against its well-known
signature row counts (99,441 orders, 112,650 order items, 103,886
payments). Kaggle itself requires an account/API token to download
directly; if you want to pull a fresh copy yourself instead of using the
bundled files:

1. Download `olistbr/brazilian-ecommerce` from Kaggle directly, **or**
   use a Kaggle API token (`kaggle datasets download -d
   olistbr/brazilian-ecommerce`).
2. You only need `olist_customers_dataset.csv`, `olist_orders_dataset.csv`,
   `olist_order_items_dataset.csv`, and `olist_order_payments_dataset.csv`
   for this project's queries — drop them into `data/real_olist_csv/`,
   overwriting the bundled copies.
3. Re-run `python3 data/load_real_olist_data.py`.

## Interview talking points this project is built to support

- **"Walk me through how you'd build a cohort retention table in SQL."**
  Start from the base fact table → `MIN() OVER` to label cohorts →
  `FIRST_VALUE() OVER` for cohort size → derive `retention_rate` → mention
  the immature-cohort scaffolding problem unprompted.
- **"What's the difference between `ROW_NUMBER`, `RANK`, and `DENSE_RANK`?"**
  `DENSE_RANK` is used here for cohort-size ranking; be ready to explain why
  ties don't skip numbers the way `RANK` would, and why `ROW_NUMBER` was
  the right (and only correct) choice for order sequencing, where ties
  must never collapse.
- **"N to N+1 retention"** — this is Part A of `03_order_sequence_and_ltv.sql`:
  of people who reached order N, what % reached order N+1, via `LEAD()`.
  This is the exact framing interviewers at Instacart-style companies ask
  for.
- **"How do you avoid a self-join when computing cumulative revenue?"**
  `SUM() OVER (PARTITION BY cohort ORDER BY period ROWS BETWEEN UNBOUNDED
  PRECEDING AND CURRENT ROW)` — walk through what the frame clause does
  and why `ROWS` (not `RANGE`) matters when `period_number` can repeat
  conceptually across partitions but not within one.
- **A classic gotcha to raise proactively**: the `customer_id` vs
  `customer_unique_id` trap described above. Bringing this up unprompted
  signals you've actually worked with messy, real-world schemas rather
  than textbook ones.
