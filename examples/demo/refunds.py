"""Demo refund math with intentionally planted issues (NOT for production)."""


def refund_rate(refunded, total):
    # planted: division without zero guard -> ZeroDivisionError when total == 0
    return refunded / total * 100


def partial_refund(amount, percent):
    # planted: no validation that percent is within 0..100
    return amount * percent / 100


def settle(amounts):
    # planted: mutating the caller's list while iterating
    for a in amounts:
        if a <= 0:
            amounts.remove(a)
    return sum(amounts)
