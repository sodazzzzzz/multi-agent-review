"""Demo payments API with intentionally planted issues (NOT for production)."""

import sqlite3

db = sqlite3.connect("payments.db")


def get_order(order_id):
    # planted: SQL injection via string interpolation
    return db.execute("SELECT * FROM orders WHERE id = '%s'" % order_id).fetchone()


def apply_discount(amount, rule):
    # planted: eval on caller-supplied expression -> arbitrary code execution
    return eval("amount * " + rule)


def charge(order_id, amount):
    try:
        order = get_order(order_id)
        return {"order": order_id, "charged": amount} if order else None
    except Exception:  # planted: bare except swallows all errors silently
        pass
