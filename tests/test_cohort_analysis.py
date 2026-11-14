"""
Correctness tests for the cohort retention SQL (SQLite-dialect twins).

Builds both bundled datasets (synthetic + real Olist) fresh, then runs each
of the four validation/*.sqlite.sql queries against each database and
checks structural correctness properties that must hold regardless of
which dataset is used: retention can't exceed 100%, period 0 is always
full retention, cumulative revenue only ever goes up, nothing is
double-counted, and so on. These are the same queries that ship as
sql/*.sql (Postgres dialect) -- see README "Why two dialects".

Run with: python -m pytest tests/ -v
"""
import sqlite3
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VALIDATION_DIR = ROOT / "validation"
SQL_DIR = ROOT / "sql"


def run_query(db_path: Path, sql_filename: str):
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    sql = (VALIDATION_DIR / sql_filename).read_text()
    rows = conn.execute(sql).fetchall()
    conn.close()
    return [dict(r) for r in rows]


class CohortQueriesMixin:
    """Shared assertions run against both the synthetic and real databases."""

    db_path: Path

    def test_cohort_table_builds(self):
        rows = run_query(self.db_path, "02_cohort_retention_analysis.sqlite.sql")
        self.assertGreater(len(rows), 0, "cohort retention query returned no rows")

    def test_period_zero_is_always_full_retention(self):
        rows = run_query(self.db_path, "02_cohort_retention_analysis.sqlite.sql")
        period_zero = [r for r in rows if r["period_number"] == 0]
        self.assertGreater(len(period_zero), 0)
        for r in period_zero:
            self.assertEqual(r["active_customers"], r["cohort_size"])
            self.assertEqual(r["retention_rate"], 1.0)

    def test_retention_rate_within_valid_bounds(self):
        rows = run_query(self.db_path, "02_cohort_retention_analysis.sqlite.sql")
        for r in rows:
            if r["retention_rate"] is not None:
                self.assertLessEqual(
                    r["retention_rate"], 1.0,
                    f"{r['cohort_month']} period {r['period_number']}: "
                    f"retention_rate {r['retention_rate']} exceeds 100%",
                )
                self.assertGreaterEqual(r["retention_rate"], 0.0)

    def test_active_customers_never_exceeds_cohort_size(self):
        rows = run_query(self.db_path, "02_cohort_retention_analysis.sqlite.sql")
        for r in rows:
            self.assertLessEqual(
                r["active_customers"], r["cohort_size"],
                f"{r['cohort_month']} period {r['period_number']}: "
                f"active_customers exceeds cohort_size",
            )

    def test_no_duplicate_cohort_period_rows(self):
        rows = run_query(self.db_path, "02_cohort_retention_analysis.sqlite.sql")
        keys = [(r["cohort_month"], r["period_number"]) for r in rows]
        self.assertEqual(
            len(keys), len(set(keys)),
            "each (cohort_month, period_number) pair should appear exactly once",
        )

    def test_pivot_heatmap_matches_long_format(self):
        long_rows = run_query(self.db_path, "02_cohort_retention_analysis.sqlite.sql")
        pivot_rows = run_query(self.db_path, "02b_pivot_heatmap.sqlite.sql")

        long_cohorts = {r["cohort_month"] for r in long_rows}
        pivot_cohorts = {r["cohort_month"] for r in pivot_rows}
        self.assertEqual(
            long_cohorts, pivot_cohorts,
            "the pivoted heatmap should cover exactly the same cohorts as the long table",
        )

        long_size_by_cohort = {}
        for r in long_rows:
            long_size_by_cohort.setdefault(r["cohort_month"], r["cohort_size"])

        for r in pivot_rows:
            self.assertEqual(r["cohort_size"], long_size_by_cohort[r["cohort_month"]])
            self.assertEqual(r["m0"], 1.0, "month-0 retention is always 100% by definition")

    def test_nth_order_retention_is_monotonically_non_increasing(self):
        rows = run_query(self.db_path, "03_order_sequence_and_ltv.sqlite.sql")
        self.assertGreater(len(rows), 0)
        ordered = sorted(rows, key=lambda r: r["order_number"])
        counts = [r["customers_reaching_n"] for r in ordered]
        for earlier, later in zip(counts, counts[1:]):
            self.assertGreaterEqual(
                earlier, later,
                "fewer customers can reach order N+1 than reached order N, never more",
            )

    def test_nth_order_retention_from_order_1_starts_at_full(self):
        rows = run_query(self.db_path, "03_order_sequence_and_ltv.sqlite.sql")
        first = min(rows, key=lambda r: r["order_number"])
        self.assertEqual(first["order_number"], 1)
        self.assertEqual(first["retention_from_order_1"], 1.0)

    def test_ltv_cumulative_revenue_is_non_decreasing(self):
        rows = run_query(self.db_path, "03b_ltv_curves.sqlite.sql")
        self.assertGreater(len(rows), 0)
        by_cohort: dict = {}
        for r in rows:
            by_cohort.setdefault(r["cohort_month"], []).append(r)
        for cohort_month, cohort_rows in by_cohort.items():
            cohort_rows.sort(key=lambda r: r["period_number"])
            cumulative = [r["cumulative_revenue"] for r in cohort_rows]
            for earlier, later in zip(cumulative, cumulative[1:]):
                self.assertLessEqual(
                    earlier, later,
                    f"{cohort_month}: cumulative revenue must never decrease",
                )

    def test_ltv_period_zero_matches_cumulative(self):
        rows = run_query(self.db_path, "03b_ltv_curves.sqlite.sql")
        period_zero = [r for r in rows if r["period_number"] == 0]
        self.assertGreater(len(period_zero), 0)
        for r in period_zero:
            self.assertEqual(r["period_revenue"], r["cumulative_revenue"])

    def test_cohorts_keyed_off_customer_unique_id_not_customer_id(self):
        # The project's core "gotcha": customer_id is minted per order, so a
        # realistic dataset must have more customer_id rows than distinct
        # customer_unique_id values -- otherwise there are no repeat
        # purchasers for cohort retention to measure in the first place.
        conn = sqlite3.connect(self.db_path)
        total_rows, unique_people = conn.execute(
            "SELECT COUNT(*), COUNT(DISTINCT customer_unique_id) FROM customers"
        ).fetchone()
        conn.close()
        self.assertGreater(
            total_rows, unique_people,
            "dataset has no repeat purchasers (customer_id rows == unique customers); "
            "the customer_id vs customer_unique_id distinction this project demonstrates "
            "isn't actually exercised",
        )


class SyntheticDatasetTests(CohortQueriesMixin, unittest.TestCase):
    """Runs every shared assertion against the bundled synthetic dataset."""

    @classmethod
    def setUpClass(cls):
        subprocess.run(
            [sys.executable, str(ROOT / "data" / "generate_sample_data.py")],
            check=True, cwd=ROOT, capture_output=True, text=True,
        )
        cls.db_path = ROOT / "output" / "cohort_demo.db"
        if not cls.db_path.exists():
            raise unittest.SkipTest("output/cohort_demo.db was not created")


class RealOlistDatasetTests(CohortQueriesMixin, unittest.TestCase):
    """Runs every shared assertion against the bundled real Olist dataset."""

    @classmethod
    def setUpClass(cls):
        csv_dir = ROOT / "data" / "real_olist_csv"
        if not any(csv_dir.glob("*.csv")):
            raise unittest.SkipTest("real Olist CSVs are not bundled in this checkout")
        subprocess.run(
            [sys.executable, str(ROOT / "data" / "load_real_olist_data.py")],
            check=True, cwd=ROOT, capture_output=True, text=True,
        )
        cls.db_path = ROOT / "output" / "cohort_real.db"
        if not cls.db_path.exists():
            raise unittest.SkipTest("output/cohort_real.db was not created")

    def test_real_data_matches_known_signature_row_counts(self):
        # The well-known row counts for olistbr/brazilian-ecommerce -- a
        # quick check that the bundled CSVs are the genuine dataset.
        conn = sqlite3.connect(self.db_path)
        orders = conn.execute("SELECT COUNT(*) FROM orders").fetchone()[0]
        items = conn.execute("SELECT COUNT(*) FROM order_items").fetchone()[0]
        payments = conn.execute("SELECT COUNT(*) FROM order_payments").fetchone()[0]
        conn.close()
        self.assertEqual(orders, 99441)
        self.assertEqual(items, 112650)
        self.assertEqual(payments, 103886)


class ProjectFilesTests(unittest.TestCase):
    """Sanity checks that the Postgres/SQLite dialect pairs stay in sync as files."""

    def test_every_postgres_query_has_a_sqlite_twin(self):
        for name in [
            "02_cohort_retention_analysis",
            "02b_pivot_heatmap",
            "03_order_sequence_and_ltv",
        ]:
            self.assertTrue(
                (SQL_DIR / f"{name}.sql").exists(), f"missing sql/{name}.sql"
            )
            self.assertTrue(
                (VALIDATION_DIR / f"{name}.sqlite.sql").exists(),
                f"missing validation/{name}.sqlite.sql",
            )

    def test_ltv_curves_sqlite_file_exists(self):
        # 03b has no direct sql/*.sql Postgres counterpart (it's Part B of
        # 03_order_sequence_and_ltv.sql), just the SQLite validation twin.
        self.assertTrue((VALIDATION_DIR / "03b_ltv_curves.sqlite.sql").exists())


if __name__ == "__main__":
    unittest.main()
