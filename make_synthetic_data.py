#!/usr/bin/env python3
"""
make_synthetic_data.py
Builds surveillance.db from schema.sql and fills it with synthetic activity:
a clean baseline plus planted cases for each detection query.

Manipulation cases (scored against ground_truth):
  - layering / spoofing        (ACC_SPOOF, MEGT)
  - wash-trade ring            (BO_RING: ACC_W1/W2/W3, JPRB)
  - pump-and-dump              (QNXH)
  - account takeover           (ACC_ATO)

Plus a multi-day firm order-flow book so the flow/imbalance/win-rate analytics
query has realistic data, including one deliberately "informed" firm (ACC001)
whose fills sit on the right side of the next session's move.

Standard library only. Deterministic (fixed seed). Run: python3 make_synthetic_data.py
"""

import os
import sqlite3
import random
from datetime import datetime, timedelta

SEED = 42
DB = "surveillance.db"
SCHEMA = "schema.sql"
random.seed(SEED)


def iso(dt):
    return dt.strftime("%Y-%m-%d %H:%M:%S")


def day(dt):
    return dt.strftime("%Y-%m-%d")


def business_days(start, n):
    days, d = [], start
    while len(days) < n:
        if d.weekday() < 5:
            days.append(d)
        d += timedelta(days=1)
    return days


def main():
    if os.path.exists(DB):
        os.remove(DB)
    con = sqlite3.connect(DB)
    con.executescript(open(SCHEMA).read())
    cur = con.cursor()

    # ----- securities -----------------------------------------------------
    securities = [
        ("MEGT", "Megatel Systems Inc",   "large_cap"),
        ("NROK", "Norrock Industries",    "large_cap"),
        ("QNXH", "Qianxi Holdings Ltd",   "small_foreign_issuer"),
        ("HKZL", "HK Zenith Group Ltd",   "small_foreign_issuer"),
        ("JPRB", "Japan Robotics Co Ltd", "small_foreign_issuer"),
    ]
    cur.executemany("INSERT INTO securities VALUES (?,?,?)", securities)
    symbols = [s[0] for s in securities]

    # ----- accounts -------------------------------------------------------
    # ACC001..ACC006 are active "firms" (institutions) that drive daily flow.
    # ACC001 is the deliberately informed firm.
    accounts = []
    for i in range(1, 31):
        acc = "ACC%03d" % i
        atype = "institution" if i <= 6 else random.choice(["retail", "prop"])
        accounts.append((acc, "BO%03d" % i, atype, "2023-01-15"))
    accounts.append(("ACC_W1", "BO_RING", "prop", "2024-02-01"))
    accounts.append(("ACC_W2", "BO_RING", "prop", "2024-02-01"))
    accounts.append(("ACC_W3", "BO_RING", "prop", "2024-02-01"))
    accounts.append(("ACC_SPOOF", "BO_SPOOF", "prop",   "2023-06-01"))
    accounts.append(("ACC_ATO",   "BO_ATO",   "retail", "2023-03-10"))
    cur.executemany("INSERT INTO accounts VALUES (?,?,?,?)", accounts)
    ordinary = ["ACC%03d" % i for i in range(1, 31)]
    firms = ["ACC%03d" % i for i in range(1, 7)]
    informed = "ACC001"

    base_day = datetime(2025, 1, 6)          # a Monday
    cal = business_days(base_day, 120)

    # ----- daily_bars: random walk + planted pump-and-dump + decoy offering
    start_px = {"MEGT": 180.0, "NROK": 95.0, "QNXH": 2.10, "HKZL": 3.40, "JPRB": 1.80}
    base_vol = {"MEGT": 3_000_000, "NROK": 1_500_000,
                "QNXH": 120_000, "HKZL": 90_000, "JPRB": 70_000}
    pump_day_idx = 80
    offering_day_idx = 55
    close_by = {s: {} for s in symbols}       # close_by[symbol][date] = close

    for sym in symbols:
        px = start_px[sym]
        vol0 = base_vol[sym]
        small = securities[symbols.index(sym)][2] == "small_foreign_issuer"
        sigma = 0.04 if small else 0.02
        for idx, d in enumerate(cal):
            ret = random.gauss(0, sigma)
            vol = int(vol0 * random.uniform(0.6, 1.4))
            if sym == "QNXH" and idx == pump_day_idx:
                ret, vol = 0.45, int(vol0 * 12)             # pump
            elif sym == "QNXH" and pump_day_idx < idx <= pump_day_idx + 3:
                ret, vol = -0.22, int(vol0 * random.uniform(3, 5))   # dump
            elif sym == "HKZL" and idx == offering_day_idx:
                ret, vol = 0.02, int(vol0 * 8)              # decoy: mechanical volume
            open_px = px
            close_px = round(px * (1 + ret), 4)
            hi = round(max(open_px, close_px) * random.uniform(1.00, 1.03), 4)
            lo = round(min(open_px, close_px) * random.uniform(0.97, 1.00), 4)
            cur.execute("INSERT INTO daily_bars VALUES (?,?,?,?,?,?,?)",
                        (sym, day(d), open_px, hi, lo, close_px, vol))
            close_by[sym][day(d)] = close_px
            px = close_px

    cur.execute("INSERT INTO ground_truth VALUES (?,?,?,?)",
                ("PD01", "pump_dump", "QNXH",
                 "12x volume + 45pct surge on %s, reverses over next 3 days" % day(cal[pump_day_idx])))

    # ----- trades: multi-day firm flow (for the analytics query) ----------
    trade_id = 0
    flow_days = cal[20:60]                     # 40 trading days of book activity
    for i, d in enumerate(flow_days):
        cal_idx = 20 + i
        next_d = cal[cal_idx + 1]              # exists (well inside range)
        for firm in firms:
            for _ in range(random.randint(1, 3)):
                sym = random.choice(symbols)
                cur_c = close_by[sym][day(d)]
                nxt_c = close_by[sym][day(next_d)]
                up = nxt_c > cur_c
                if firm == informed:
                    # sit on the right side ~85% of the time
                    side = ("buy" if up else "sell") if random.random() < 0.85 \
                           else ("sell" if up else "buy")
                else:
                    side = random.choice(["buy", "sell"])
                price = round(cur_c * random.uniform(0.999, 1.001), 4)
                qty = random.randint(500, 5000)
                counter = random.choice([a for a in firms + ordinary if a != firm])
                buyer, seller = (firm, counter) if side == "buy" else (counter, firm)
                ts = d + timedelta(hours=10, minutes=random.randint(0, 350))
                trade_id += 1
                cur.execute("INSERT INTO trades VALUES (?,?,?,?,?,?,?)",
                            ("TRD%05d" % trade_id, sym, buyer, seller, price, qty, iso(ts)))

    # Planted WASH-TRADE RING: 3 accounts under one owner circulating stock
    # among themselves (6 internal trades) with a single external trade so the
    # internal-circulation ratio is high but not a suspicious flat 1.00.
    ring_day = cal[30]
    cycle = [("ACC_W1", "ACC_W2"), ("ACC_W2", "ACC_W3"), ("ACC_W3", "ACC_W1")]
    for k in range(6):
        buyer, seller = cycle[k % 3]
        ts = ring_day + timedelta(hours=10, minutes=15 * k)
        trade_id += 1
        cur.execute("INSERT INTO trades VALUES (?,?,?,?,?,?,?)",
                    ("TRD%05d" % trade_id, "JPRB", buyer, seller, 1.80, 4000, iso(ts)))
    # one external trade (ring account sells to an outside account)
    trade_id += 1
    cur.execute("INSERT INTO trades VALUES (?,?,?,?,?,?,?)",
                ("TRD%05d" % trade_id, "JPRB", "ACC015", "ACC_W1", 1.80, 4000,
                 iso(ring_day + timedelta(hours=13))))
    cur.execute("INSERT INTO ground_truth VALUES (?,?,?,?)",
                ("WT01", "wash_trade", "BO_RING",
                 "ring of ACC_W1/W2/W3 circulating JPRB among themselves"))

    # ----- quotes + baseline orders for MEGT + planted layering -----------
    sess = datetime(2025, 3, 3, 9, 30, 0)
    quote_bid = 180.00
    order_id = 0
    quotes_times = []
    for m in range(390):
        ts = sess + timedelta(minutes=m)
        quote_bid = round(quote_bid + random.gauss(0, 0.03), 2)
        bid = quote_bid
        ask = round(bid + 0.02, 2)
        cur.execute("INSERT INTO quotes VALUES (?,?,?,?)", ("MEGT", iso(ts), bid, ask))
        quotes_times.append((ts, bid, ask))

    def nearest_quote(ts):
        best = quotes_times[0]
        for q in quotes_times:
            if q[0] <= ts:
                best = q
            else:
                break
        return best

    for _ in range(120):
        ts = sess + timedelta(minutes=random.randint(0, 389), seconds=random.randint(0, 59))
        _, bid, ask = nearest_quote(ts)
        side = random.choice(["buy", "sell"])
        acc = random.choice(ordinary)
        qty = random.randint(100, 900)
        if random.random() < 0.2:
            price = round((bid - 0.10) if side == "buy" else (ask + 0.10), 2)
            cxl = ts + timedelta(seconds=random.randint(120, 600))
            status, ts_cxl = "cancelled", iso(cxl)
        else:
            price = round(bid if side == "buy" else ask, 2)
            status, ts_cxl = "filled", None
        order_id += 1
        cur.execute("INSERT INTO orders VALUES (?,?,?,?,?,?,?,?,?,?)",
                    ("ORD%05d" % order_id, "MEGT", acc, side, price, qty, "limit",
                     iso(ts), ts_cxl, status))

    spoof_start = sess + timedelta(minutes=150)
    _, bid, ask = nearest_quote(spoof_start)
    for k in range(4):
        ts = spoof_start + timedelta(seconds=10 * k)
        cxl = ts + timedelta(seconds=25)
        order_id += 1
        cur.execute("INSERT INTO orders VALUES (?,?,?,?,?,?,?,?,?,?)",
                    ("ORD%05d" % order_id, "MEGT", "ACC_SPOOF", "buy",
                     round(bid, 2), 6000, "limit", iso(ts), iso(cxl), "cancelled"))
    sell_ts = spoof_start + timedelta(seconds=35)
    order_id += 1
    cur.execute("INSERT INTO orders VALUES (?,?,?,?,?,?,?,?,?,?)",
                ("ORD%05d" % order_id, "MEGT", "ACC_SPOOF", "sell",
                 round(ask, 2), 5000, "limit", iso(sell_ts), None, "filled"))
    cur.execute("INSERT INTO ground_truth VALUES (?,?,?,?)",
                ("LY01", "layering", "ACC_SPOOF",
                 "4 near-touch buy limits cancelled <30s + opposite-side sell fill on MEGT"))

    # ----- access_log + planted ATO --------------------------------------
    for acc in ordinary + ["ACC_W1", "ACC_W2", "ACC_W3", "ACC_SPOOF", "ACC_ATO"]:
        geo = random.choice(["US-PA", "US-NY", "US-CA", "US-TX", "US-FL"])
        dev = "dev-%s" % acc.lower()
        ipp = "71.%d.%d.%d" % (random.randint(1, 250), random.randint(1, 250), random.randint(1, 250))
        for dn in range(0, 100, 7):
            ts = base_day + timedelta(days=dn, hours=9, minutes=random.randint(0, 300))
            cur.execute("INSERT INTO access_log VALUES (?,?,?,?,?,?)",
                        (acc, iso(ts), ipp, geo, dev, "login"))

    for dn in range(0, 90, 10):
        ts = base_day + timedelta(days=dn, hours=10, minutes=random.randint(0, 200))
        order_id += 1
        cur.execute("INSERT INTO orders VALUES (?,?,?,?,?,?,?,?,?,?)",
                    ("ORD%05d" % order_id, "MEGT", "ACC_ATO", "buy",
                     round(start_px["MEGT"], 2), random.randint(100, 400),
                     "limit", iso(ts), None, "filled"))

    ato_login = base_day + timedelta(days=95, hours=2, minutes=14)
    cur.execute("INSERT INTO access_log VALUES (?,?,?,?,?,?)",
                ("ACC_ATO", iso(ato_login), "185.220.101.7", "RU-MOW", "dev-9f3a11", "login"))
    cur.execute("INSERT INTO access_log VALUES (?,?,?,?,?,?)",
                ("ACC_ATO", iso(ato_login + timedelta(minutes=1)),
                 "185.220.101.7", "RU-MOW", "dev-9f3a11", "password_reset"))
    order_id += 1
    cur.execute("INSERT INTO orders VALUES (?,?,?,?,?,?,?,?,?,?)",
                ("ORD%05d" % order_id, "QNXH", "ACC_ATO", "buy",
                 2.10, 25000, "market", iso(ato_login + timedelta(minutes=6)), None, "filled"))
    cur.execute("INSERT INTO ground_truth VALUES (?,?,?,?)",
                ("AT01", "ato", "ACC_ATO",
                 "login from RU-MOW/new device then large QNXH buy (never-traded symbol)"))

    con.commit()

    def count(tbl):
        return cur.execute("SELECT COUNT(*) FROM %s" % tbl).fetchone()[0]
    print("Built %s" % DB)
    for t in ["securities", "accounts", "quotes", "orders", "trades",
              "daily_bars", "access_log", "ground_truth"]:
        print("  %-12s %6d rows" % (t, count(t)))
    con.close()


if __name__ == "__main__":
    main()
