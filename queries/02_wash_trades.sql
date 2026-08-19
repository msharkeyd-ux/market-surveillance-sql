-- 02_wash_trades.sql
-- RED FLAG: wash-trade ring. A set of accounts under common control circulates the
--   same stock among themselves, manufacturing tape volume without transferring real
--   risk to any outside party.
-- LOGIC: attribute both sides of every trade to a beneficial owner; for each owner
--   that controls 2+ accounts, measure the share of the trades it touches that stay
--   INTERNAL (both sides its own accounts). A high internal-circulation ratio is the
--   ring signal. Rank owners by that ratio so the output reads like a triage queue.
-- CAVEAT: related accounts can trade legitimately. The tell is the closed-loop
--   circulation, not shared ownership alone. Alert for human review.
-- REVIEW OUTPUT: owner, accounts controlled, wash trades, trades touched, ratio, rank.

WITH acct_owner AS (
  SELECT account_id, beneficial_owner_id AS owner FROM accounts
),
trade_owners AS (
  SELECT t.trade_id, t.qty,
         bo.owner AS buy_owner,
         so.owner AS sell_owner
  FROM trades t
  JOIN acct_owner bo ON bo.account_id = t.buy_account_id
  JOIN acct_owner so ON so.account_id = t.sell_account_id
),
touched AS (                              -- distinct trades each owner is a party to
  SELECT owner, COUNT(DISTINCT trade_id) AS trades_touched
  FROM (
    SELECT trade_id, buy_owner  AS owner FROM trade_owners
    UNION ALL
    SELECT trade_id, sell_owner AS owner FROM trade_owners
  )
  GROUP BY owner
),
internal AS (                             -- both sides the same owner = self-dealing
  SELECT buy_owner AS owner,
         COUNT(*)  AS wash_trades,
         SUM(qty)  AS wash_qty
  FROM trade_owners
  WHERE buy_owner = sell_owner
  GROUP BY buy_owner
),
owner_accounts AS (
  SELECT owner, COUNT(*) AS n_accounts FROM acct_owner GROUP BY owner
)
SELECT
  i.owner                                          AS beneficial_owner,
  oa.n_accounts,
  i.wash_trades,
  i.wash_qty,
  t.trades_touched,
  ROUND(i.wash_trades * 1.0 / t.trades_touched, 2) AS internal_ratio,
  RANK() OVER (ORDER BY i.wash_trades * 1.0 / t.trades_touched DESC,
                        i.wash_trades DESC)         AS severity_rank
FROM internal i
JOIN touched        t  ON t.owner  = i.owner
JOIN owner_accounts oa ON oa.owner = i.owner
WHERE oa.n_accounts >= 2                  -- ring-capable: owner controls multiple accounts
ORDER BY severity_rank;
