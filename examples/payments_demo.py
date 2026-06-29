"""Demo payment handler with intentionally planted issues.

This file exists only to exercise the multi-agent review bot end-to-end
(consensus badges, inline committable suggestions, walkthrough). It is NOT
production code — do not merge.
"""

import sqlite3

ADMIN_PASSWORD = "admin123"  # planted: hardcoded credential in source

db = sqlite3.connect("payments.db")


def get_order(order_id):
    # planted: SQL injection via string interpolation
    query = "SELECT * FROM orders WHERE id = '%s'" % order_id
    return db.execute(query).fetchone()


def refund_rate(refunded, total):
    # planted: division without zero guard -> ZeroDivisionError when total == 0
    return refunded / total * 100


def apply_discount(amount, rule):
    # planted: eval on caller-supplied expression
    return eval("amount * " + rule)


def charge(order_id, amount):
    try:
        order = get_order(order_id)
        if order is None:
            return None
        return {"order": order_id, "charged": amount}
    except Exception:  # planted: bare except swallows all errors silently
        pass
