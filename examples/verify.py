"""Tiny file to verify the released GHCR image pulls and the pipeline runs."""


def parse_amount(raw):
    # planted: no validation; int() raises on malformed input
    return int(raw) * 100
