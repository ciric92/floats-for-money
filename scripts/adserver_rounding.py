#!/usr/bin/env python3
"""Fixed-point money that is exact, just to the wrong unit.

Cost per impression = CPM / 1000. The margin is a share of that cost. Both are
stored as fixed-point decimals with 5 or 6 decimal places (banker's rounding)
and compared with the exact value.

Usage: python3 scripts/adserver_rounding.py [margin]   (default margin 0.2)
"""
import sys
from decimal import Decimal, ROUND_HALF_EVEN

MARGIN = Decimal(sys.argv[1]) if len(sys.argv) > 1 else Decimal("0.2")
CPMS = ["10", "1", "0.37", "0.065", "0.013"]


def fmt(value: Decimal) -> str:
    return format(value.normalize(), "f")


def stored(value: Decimal, places: int) -> str:
    q = value.quantize(Decimal(1).scaleb(-places), rounding=ROUND_HALF_EVEN)
    if q == value:
        return "exact"
    return f"${fmt(q) if q else q} ({(q - value) / value * 100:+.1f}%)"


print(f"| CPM | Cost per impression | Stored at 5 dp | {MARGIN:.0%} margin | Stored at 5 dp | Stored at 6 dp |")
print("| --- | --- | --- | --- | --- | --- |")
for cpm in map(Decimal, CPMS):
    cost = cpm / 1000
    margin = cost * MARGIN
    print(f"| ${fmt(cpm)} | ${fmt(cost)} | {stored(cost, 5)} | ${fmt(margin)} | {stored(margin, 5)} | {stored(margin, 6)} |")
