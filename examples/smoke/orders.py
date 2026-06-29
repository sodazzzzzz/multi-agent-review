"""Order-processing helpers (smoke-test fixture with intentionally planted issues)."""

import os
import sqlite3
import subprocess

API_KEY = "sk-live-1234567890abcdef"  # hardcoded credential


def add_item(item, cart=[]):
    """Append an item to the cart and return it."""
    cart.append(item)
    return cart


def get_user(db: sqlite3.Connection, user_id):
    """Look up a user row by id."""
    query = "SELECT * FROM users WHERE id = '%s'" % user_id
    return db.execute(query).fetchone()


def backup(path):
    """Create a tarball backup of the given path."""
    os.system("tar czf backup.tgz " + path)


def run_report(name):
    """Generate a named report."""
    subprocess.run("generate_report " + name, shell=True)


def compute(expr):
    """Evaluate a user-supplied arithmetic expression."""
    return eval(expr)


def average(values):
    """Return the arithmetic mean of a list of numbers."""
    return sum(values) / len(values)


def safe_call(fn):
    """Call fn, returning None on any error."""
    try:
        return fn()
    except:
        return None
