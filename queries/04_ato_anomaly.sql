-- 04_ato_anomaly.sql
-- RED FLAG: account takeover. A login breaks from the account's baseline (a geo the
--   account has never used) and is immediately followed by trading that also breaks
--   baseline (a symbol the account has never traded).
-- LOGIC: find logins from a never-before-seen geo for an account that already has
--   history; join to orders placed within 30 minutes in a symbol the account had
--   never traded before that login.
-- CAVEAT: people travel and buy new devices. The discriminator is the login break
--   AND the trading break, tightly coupled in time. Alert for human review.
-- REVIEW OUTPUT: account, login (geo/device/ip), the anomalous order that followed.

WITH new_geo_logins AS (
  SELECT a.account_id, a.ts AS login_ts, a.geo, a.device_id, a.ip
  FROM access_log a
  WHERE a.event = 'login'
    AND NOT EXISTS (                         -- geo never seen for this account before
          SELECT 1 FROM access_log p
          WHERE p.account_id = a.account_id
            AND p.event = 'login'
            AND p.ts < a.ts
            AND p.geo = a.geo )
    AND EXISTS (                             -- but the account DOES have prior history
          SELECT 1 FROM access_log h
          WHERE h.account_id = a.account_id
            AND h.ts < a.ts )
)
SELECT
  g.account_id,
  g.login_ts,
  g.geo         AS new_geo,
  g.device_id,
  g.ip,
  o.order_id,
  o.symbol      AS traded_symbol,
  o.side,
  o.qty,
  o.ts_placed
FROM new_geo_logins g
JOIN orders o
  ON  o.account_id = g.account_id
  AND julianday(o.ts_placed) BETWEEN julianday(g.login_ts)
                                 AND julianday(g.login_ts) + 30.0/1440.0   -- 30 minutes
  AND NOT EXISTS (                           -- symbol the account never traded before
        SELECT 1 FROM orders o2
        WHERE o2.account_id = g.account_id
          AND o2.symbol     = o.symbol
          AND o2.ts_placed  < g.login_ts )
ORDER BY g.login_ts;
