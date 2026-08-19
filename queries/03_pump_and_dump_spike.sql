-- 03_pump_and_dump_spike.sql
-- RED FLAG: coordinated ramp. A thin issuer sees a volume explosion and a sharp price
--   surge over a short window, then reverses (the dump).
-- LOGIC: per symbol/date, compute the trailing 20-session average volume, the daily
--   return, and the lowest close over the NEXT 5 sessions (all before filtering, so the
--   forward window sees every day, not just other spike days); then keep days whose
--   volume and return both clear threshold, and flag whether a reversal followed.
-- CAVEAT: mechanical volume (offerings, IPO pricing, index events) spikes volume
--   WITHOUT a price surge, so the return gate filters those out on purpose. This is
--   the trade-layer signal an EDGAR-filings-only screen cannot see. Alert for review.
-- REVIEW OUTPUT: symbol, date, volume, trailing avg, volume ratio, return %, reversal.

WITH bars AS (
  SELECT
    symbol, date, close, volume,
    AVG(volume) OVER (
      PARTITION BY symbol ORDER BY date
      ROWS BETWEEN 20 PRECEDING AND 1 PRECEDING
    ) AS trailing_avg_vol,
    close / LAG(close) OVER (PARTITION BY symbol ORDER BY date) - 1 AS ret,
    MIN(close) OVER (
      PARTITION BY symbol ORDER BY date
      ROWS BETWEEN 1 FOLLOWING AND 5 FOLLOWING
    ) AS min_close_next_5
  FROM daily_bars
)
SELECT
  symbol,
  date,
  volume,
  CAST(trailing_avg_vol AS INT)              AS trailing_avg_vol,
  ROUND(volume * 1.0 / trailing_avg_vol, 1)  AS vol_ratio,
  ROUND(ret * 100, 1)                        AS ret_pct,
  CASE WHEN min_close_next_5 <= close * 0.80
       THEN 1 ELSE 0 END                     AS reversed_next_5
FROM bars
WHERE trailing_avg_vol > 0
  AND volume >= 5 * trailing_avg_vol
  AND ret    >= 0.25
ORDER BY vol_ratio DESC;
