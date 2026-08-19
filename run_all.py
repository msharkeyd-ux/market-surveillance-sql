#!/usr/bin/env python3
"""
run_all.py
Runs each detection query against surveillance.db. The four manipulation queries are
scored against the ground_truth answer key (caught / missed / false positives). The
flow analytics query (05) is a triage blotter, not a labeled catch, so it is displayed
and its top-ranked account is noted rather than scored.
Standard library only. Run: python3 run_all.py
"""

import sqlite3

DB = "surveillance.db"

SCORED = [
    ("queries/01_layering_spoofing.sql",   "layering",   "account_id"),
    ("queries/02_wash_trades.sql",         "wash_trade", "beneficial_owner"),
    ("queries/03_pump_and_dump_spike.sql", "pump_dump",  "symbol"),
    ("queries/04_ato_anomaly.sql",         "ato",        "account_id"),
]
ANALYTICS = ("queries/05_flow_imbalance_winrate.sql", "flow blotter (ranked, not scored)")


def show(rows):
    if not rows:
        print("   (no alerts)")
        return
    cols = rows[0].keys()
    print("   " + " | ".join(cols))
    for r in rows:
        print("   " + " | ".join(str(r[c]) for c in cols))


def run():
    con = sqlite3.connect(DB)
    con.row_factory = sqlite3.Row
    truth = {}
    for row in con.execute("SELECT scenario, entity_ref FROM ground_truth"):
        truth.setdefault(row["scenario"], set()).add(row["entity_ref"])

    print("=" * 72)
    print("market-surveillance-sql  |  detection run")
    print("=" * 72)

    for path, scenario, key_col in SCORED:
        rows = con.execute(open(path).read()).fetchall()
        print("\n### %s  (target: %s)" % (path, scenario))
        show(rows)
        planted = truth.get(scenario, set())
        flagged = set(str(r[key_col]) for r in rows)
        caught, missed, fp = planted & flagged, planted - flagged, flagged - planted
        recall = len(caught) / len(planted) if planted else 0.0
        precision = len(caught) / len(flagged) if flagged else 0.0
        print("   score: caught %d/%d  false positives %d  |  recall %.2f  precision %.2f"
              % (len(caught), len(planted), len(fp), recall, precision))
        if missed:
            print("   MISSED:", ", ".join(sorted(missed)))
        if fp:
            print("   FALSE POSITIVES:", ", ".join(sorted(fp)))

    # analytics blotter
    path, label = ANALYTICS
    rows = con.execute(open(path).read()).fetchall()
    print("\n### %s  (%s)" % (path, label))
    show(rows)
    if rows:
        top = rows[0]
        print("   top by win rate: %s  (win_rate %s, participation %s) -> the account to review first"
              % (top["account_id"], top["win_rate"], top["participation"]))

    print("\nNote: synthetic data with planted cases. Perfect scores on the four catch")
    print("queries mean the logic expresses each pattern correctly, NOT that it would")
    print("work on real market data. Query 05 is an analyst blotter, not a detector.")
    con.close()


if __name__ == "__main__":
    run()
