-- schema.sql
-- market-surveillance-sql: synthetic order/trade/market/access data model.
-- All timestamps are ISO 8601 strings ('YYYY-MM-DD HH:MM:SS'); dates are 'YYYY-MM-DD'.
-- Rebuildable from make_synthetic_data.py. Nothing here is real market data.

DROP TABLE IF EXISTS securities;
CREATE TABLE securities (
    symbol       TEXT PRIMARY KEY,
    name         TEXT NOT NULL,
    issuer_type  TEXT NOT NULL            -- 'large_cap' | 'small_foreign_issuer'
);

DROP TABLE IF EXISTS accounts;
CREATE TABLE accounts (
    account_id           TEXT PRIMARY KEY,
    beneficial_owner_id  TEXT NOT NULL,   -- the join that makes wash-trade linkage possible
    account_type         TEXT NOT NULL,   -- 'retail' | 'prop' | 'institution'
    open_date            TEXT NOT NULL
);

DROP TABLE IF EXISTS quotes;
CREATE TABLE quotes (
    symbol  TEXT NOT NULL,
    ts      TEXT NOT NULL,
    bid     REAL NOT NULL,
    ask     REAL NOT NULL
);
CREATE INDEX idx_quotes_symbol_ts ON quotes(symbol, ts);

DROP TABLE IF EXISTS orders;
CREATE TABLE orders (
    order_id      TEXT PRIMARY KEY,
    symbol        TEXT NOT NULL,
    account_id    TEXT NOT NULL,
    side          TEXT NOT NULL,          -- 'buy' | 'sell'
    price         REAL NOT NULL,
    qty           INTEGER NOT NULL,
    order_type    TEXT NOT NULL,          -- 'limit' | 'market'
    ts_placed     TEXT NOT NULL,
    ts_cancelled  TEXT,                   -- NULL unless cancelled
    status        TEXT NOT NULL           -- 'filled' | 'cancelled' | 'open'
);
CREATE INDEX idx_orders_symbol_ts ON orders(symbol, ts_placed);
CREATE INDEX idx_orders_account   ON orders(account_id);

DROP TABLE IF EXISTS trades;
CREATE TABLE trades (
    trade_id         TEXT PRIMARY KEY,
    symbol           TEXT NOT NULL,
    buy_account_id   TEXT NOT NULL,
    sell_account_id  TEXT NOT NULL,
    price            REAL NOT NULL,
    qty              INTEGER NOT NULL,
    ts               TEXT NOT NULL
);
CREATE INDEX idx_trades_symbol_ts ON trades(symbol, ts);

DROP TABLE IF EXISTS daily_bars;
CREATE TABLE daily_bars (
    symbol  TEXT NOT NULL,
    date    TEXT NOT NULL,
    open    REAL NOT NULL,
    high    REAL NOT NULL,
    low     REAL NOT NULL,
    close   REAL NOT NULL,
    volume  INTEGER NOT NULL,
    PRIMARY KEY (symbol, date)
);

DROP TABLE IF EXISTS access_log;
CREATE TABLE access_log (
    account_id  TEXT NOT NULL,
    ts          TEXT NOT NULL,
    ip          TEXT NOT NULL,
    geo         TEXT NOT NULL,            -- coarse region code, e.g. 'US-PA', 'RU-MOW'
    device_id   TEXT NOT NULL,
    event       TEXT NOT NULL            -- 'login' | 'logout' | 'password_reset'
);
CREATE INDEX idx_access_account_ts ON access_log(account_id, ts);

-- Ground-truth labels for the planted cases. Lets each query report how it did
-- on a known answer key instead of just returning rows. This is the validator move.
DROP TABLE IF EXISTS ground_truth;
CREATE TABLE ground_truth (
    case_id     TEXT PRIMARY KEY,
    scenario    TEXT NOT NULL,           -- 'layering' | 'wash_trade' | 'pump_dump' | 'ato'
    entity_ref  TEXT NOT NULL,           -- symbol or account_id the case attaches to
    note        TEXT
);
