-- 01_layering_spoofing.sql
-- RED FLAG: false depth. An account posts several large limit orders right at the
--   touch on one side of the book, cancels them within seconds without filling
--   (fake pressure), then executes on the OPPOSITE side into the move it created.
-- LOGIC: keep limit orders that are large, cancelled unfilled, short-lived, and
--   priced within a tick of the prevailing quote; require >= 3 on the same side in
--   a tight window; then require an opposite-side FILL by the same account nearby.
-- CAVEAT: legitimate market makers cancel constantly. The discriminator is the
--   near-touch cluster PLUS the opposite-side execution, not the cancel rate alone.
--   This is an alert for human review, not a determination of intent.
-- REVIEW OUTPUT: account, symbol, spoof side, order count, window, the opposite fill.

WITH tagged AS (
  SELECT
    o.order_id, o.symbol, o.account_id, o.side, o.price, o.qty,
    o.ts_placed, o.ts_cancelled,
    (SELECT q.bid FROM quotes q
       WHERE q.symbol = o.symbol AND q.ts <= o.ts_placed
       ORDER BY q.ts DESC LIMIT 1)                        AS eff_bid,
    (SELECT q.ask FROM quotes q
       WHERE q.symbol = o.symbol AND q.ts <= o.ts_placed
       ORDER BY q.ts DESC LIMIT 1)                        AS eff_ask,
    (julianday(o.ts_cancelled) - julianday(o.ts_placed)) * 86400.0 AS life_s
  FROM orders o
  WHERE o.order_type = 'limit'
    AND o.status = 'cancelled'
    AND o.ts_cancelled IS NOT NULL
),
spoof AS (                          -- large, near-touch, short-lived, unfilled cancels
  SELECT * FROM tagged
  WHERE qty >= 3000
    AND life_s < 90
    AND ( (side = 'buy'  AND ABS(price - eff_bid) <= 0.02)
       OR (side = 'sell' AND ABS(price - eff_ask) <= 0.02) )
),
clusters AS (                       -- >= 3 same-side spoof orders inside a 5-min window
  SELECT account_id, symbol, side,
         COUNT(*)       AS spoof_orders,
         MIN(ts_placed) AS win_start,
         MAX(ts_placed) AS win_end
  FROM spoof
  GROUP BY account_id, symbol, side
  HAVING COUNT(*) >= 3
     AND (julianday(MAX(ts_placed)) - julianday(MIN(ts_placed))) * 86400.0 <= 300
)
SELECT
  c.account_id,
  c.symbol,
  c.side                AS spoof_side,
  c.spoof_orders,
  c.win_start,
  c.win_end,
  f.order_id            AS opposite_fill_order,
  f.side                AS fill_side,
  f.qty                 AS fill_qty
FROM clusters c
JOIN orders f
  ON  f.account_id = c.account_id
  AND f.symbol     = c.symbol
  AND f.status     = 'filled'
  AND f.side <> c.side
  AND julianday(f.ts_placed) BETWEEN julianday(c.win_start) - 300.0/86400.0
                                 AND julianday(c.win_end)   + 300.0/86400.0
ORDER BY c.spoof_orders DESC;
