"""Demo payment helpers — intentionally buggy fixture to exercise the review bot."""

import os
import sqlite3


def find_user(db: sqlite3.Connection, user_id):
    # Bug: SQL injection — user_id is concatenated straight into the query.
    cur = db.cursor()
    cur.execute("SELECT * FROM users WHERE id = " + user_id)
    return cur.fetchone()


def apply_discount(prices, total_items):
    # Bug: division by zero when total_items is 0.
    average = sum(prices) / total_items
    return average


def run_report(report_name):
    # Bug: command injection — report_name flows into a shell unsanitised.
    os.system("generate_report " + report_name)


def parse_config(raw):
    # Bug: eval of untrusted input — arbitrary code execution.
    return eval(raw)


def collect(items=[]):
    # Bug: mutable default argument — shared across calls.
    items.append("x")
    return items
