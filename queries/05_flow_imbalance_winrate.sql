-- 05_flow_imbalance_winrate.sql
-- PURPOSE: analyst flow blotter, not a labeled-catch query. Mirrors the kind of
--   multi-condition aggregation run against CAT data: per-account directional
--   imbalance, share of tape (participation), and hit rate versus the next session's
--   move. Surfaces accounts whose flow is both one-sided AND consistently on the right
--   side of the market, which is where you point a reviewer next.
-- LOGIC: unpivot each trade to its buy-side and sell-side account; grade each fill a
--   win if the next session's close moved the account's way (buys that go up, sells
--   that go down); aggregate per account into imbalance, participation, and win rate;
--   rank by win rate then absolute imbalance.
-- CAVEAT: next-session close is a crude P&L proxy on synthetic data. A high win rate
--   is a lead to investigate (informed/abusive flow), never a conclusion.
-- OUTPUT: account, trades, volume, buy/sell qty, net imbalance, participation, win
--   rate, attention rank.

WITH account_trades AS (
  SELECT buy_account_id  AS account_id, symbol, ts, price, qty, 'buy'  AS side FROM trades
  UNION ALL
  SELECT sell_account_id AS account_id, symbol, ts, price, qty, 'sell' AS side FROM trades
),
bars_next AS (
  SELECT symbol, date, close,
         LEAD(close) OVER (PARTITION BY symbol ORDER BY date) AS next_close
  FROM daily_bars
),
scored AS (
  SELECT
    at.account_id, at.symbol, at.side, at.price, at.qty,
    CASE WHEN at.side = 'buy'  AND bn.next_close > at.price THEN 1
         WHEN at.side = 'sell' AND bn.next_close < at.price THEN 1
         ELSE 0 END AS win
  FROM account_trades at
  JOIN bars_next bn
    ON bn.symbol = at.symbol
   AND bn.date   = date(at.ts)
  WHERE bn.next_close IS NOT NULL
),
per_account AS (
  SELECT
    account_id,
    COUNT(*)                                        AS trades,
    SUM(qty)                                        AS volume,
    SUM(CASE WHEN side = 'buy'  THEN qty ELSE 0 END) AS buy_qty,
    SUM(CASE WHEN side = 'sell' THEN qty ELSE 0 END) AS sell_qty,
    ROUND(SUM(win) * 1.0 / COUNT(*), 2)             AS win_rate
  FROM scored
  GROUP BY account_id
)
SELECT
  account_id,
  trades,
  volume,
  buy_qty,
  sell_qty,
  ROUND((buy_qty - sell_qty) * 1.0 / volume, 2)          AS net_imbalance,
  ROUND(volume * 1.0 / SUM(volume) OVER (), 3)           AS participation,
  win_rate,
  RANK() OVER (ORDER BY win_rate DESC,
                        ABS(buy_qty - sell_qty) DESC)     AS attention_rank
FROM per_account
WHERE trades >= 5                       -- enough sample to rank
ORDER BY attention_rank
LIMIT 12;
