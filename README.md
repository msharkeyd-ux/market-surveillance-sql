# market-surveillance-sql

A zero-setup SQLite database of synthetic order, trade, market, and access-log data, plus a documented set of market-surveillance detection queries. Each query targets a specific manipulation red flag and carries a header comment explaining the logic, the caveats, and what a human reviewer should look at.

## What this is, and what it is not

The data is **synthetic** and the abusive cases are **planted**, so the catch queries fire by construction. This repo demonstrates that I can translate the red flags a surveillance system encodes into correct, reproducible detection logic in my own domain. It is a demonstration of detection logic and domain judgment. It is **not** a validated detector and it makes no claim to work on real market data.

That distinction matters. Over-claiming an unvalidated model as a working detector is exactly the failure mode a model-validation function exists to catch, so the framing here stays honest on purpose. (For actual validation studies, see the companion repos below.)

## The queries

Four catch queries, each scored against a labeled answer key, plus one analyst blotter.

| Query | Red flag | Core SQL |
|-------|----------|----------|
| `01_layering_spoofing.sql` | False depth. Large near-touch orders posted then pulled to fake pressure, with an execution on the opposite side. | As-of correlated subquery to the quote in effect at order time, time-window math, opposite-side self-join. |
| `02_wash_trades.sql` | Wash-trade ring. Accounts under common control circulate stock among themselves. | Owner attribution on both sides, internal-circulation ratio (internal trades over trades touched), severity rank. |
| `03_pump_and_dump_spike.sql` | Coordinated ramp. Volume explosion plus price surge, then reversal. | Trailing-average and forward-looking window frames, `LAG` returns, reversal flag. |
| `04_ato_anomaly.sql` | Account takeover. A login break followed by a trading break. | Stacked `NOT EXISTS` anti-joins for never-seen geo and never-traded symbol, tight time coupling. |
| `05_flow_imbalance_winrate.sql` | Analyst flow blotter (ranked, not a labeled catch). | Unpivot to per-account fills, `LEAD` next-session P&L proxy, imbalance, participation, ranked win rate. |

Every catch query returns candidate cases plus the evidence a reviewer needs. These are **alerts for human review, not determinations**.

## Query 05 in particular

`05_flow_imbalance_winrate.sql` is modeled on the kind of multi-condition aggregation an analyst runs against CAT data: per-account directional imbalance, share of the tape (participation), and hit rate versus the next session's move, all ranked into a review queue. It is deliberately not scored against ground truth, because a high win rate is a lead to investigate, not a labeled offense. On the synthetic book it ranks the one "informed" account to the top, and the point worth making is that it tops the queue by pairing a high win rate with real participation. The small-sample accounts sitting near it on win rate alone are noise, which is exactly the read discipline the ranking is there to enforce.

## Schema

Seven data tables plus a labels table. All timestamps are ISO 8601 strings.

- `securities` — symbols and issuer type (large cap vs small foreign issuer)
- `accounts` — account id, beneficial owner id (the link for ring detection), type
- `quotes` — per-minute bid/ask, the touch reference for the layering screen
- `orders` — full order lifecycle (placed, cancelled, filled)
- `trades` — executions with buy and sell account
- `daily_bars` — OHLCV, the pump-and-dump and win-rate screens
- `access_log` — logins with geo/device/ip, the account-takeover screen
- `ground_truth` — labels for the planted cases, so each catch query can be scored

## Run it

Three steps. Standard library only, no pip installs.

```bash
# 1. build the empty database from the schema
sqlite3 surveillance.db < schema.sql

# 2. fill it with synthetic activity + planted cases (deterministic)
python3 make_synthetic_data.py

# 3. run every query and score the four catch queries against the answer key
python3 run_all.py
```

You can also open `surveillance.db` in [DB Browser for SQLite](https://sqlitebrowser.org/) and run any query in `queries/` by hand.

## Results

Against the planted answer key, each catch query recovers its case with no false positives:

```
01_layering_spoofing    caught 1/1   false positives 0   recall 1.00  precision 1.00
02_wash_trades          caught 1/1   false positives 0   recall 1.00  precision 1.00
03_pump_and_dump_spike  caught 1/1   false positives 0   recall 1.00  precision 1.00
04_ato_anomaly          caught 1/1   false positives 0   recall 1.00  precision 1.00
05_flow_imbalance       (blotter) top by win rate: the informed account, at rank 1
```

One deliberate control: the dataset also plants a registered-offering day (roughly 8x normal volume, about +2% price move). The pump-and-dump screen **does not** flag it, because the return gate filters out mechanical volume that arrives without a price surge. Catching the ramp while ignoring the offering is the point.

## The wider portfolio

This repo is the detection-logic layer of a four-part story:

- **[edgar-pnd-validation](https://github.com/msharkeyd-ux/edgar-pnd-validation)** and **[pnd-multisignal](https://github.com/msharkeyd-ux/pnd-multisignal)** — honest model-validation studies on whether pump-and-dump manipulation is detectable from public data, framed to SR 11-7.
- **[decision-validation-harness](https://github.com/msharkeyd-ux/decision-validation-harness)** — an offline harness that validates an AI decision model and emits a governance artifact mapped to NIST AI RMF, EU AI Act, SR 11-7, and SR 26-2.
- **market-surveillance-sql** (this repo) — the detection logic itself, written in the analyst's own domain.

Together: write the detection logic, validate the model's output, study the signals, and emit the governance artifact.

## Repo layout

```
market-surveillance-sql/
├── schema.sql                 # data model
├── make_synthetic_data.py     # deterministic data + planted cases
├── run_all.py                 # runs every query, scores catch queries vs ground_truth
├── queries/
│   ├── 01_layering_spoofing.sql
│   ├── 02_wash_trades.sql
│   ├── 03_pump_and_dump_spike.sql
│   ├── 04_ato_anomaly.sql
│   └── 05_flow_imbalance_winrate.sql
└── README.md
```
