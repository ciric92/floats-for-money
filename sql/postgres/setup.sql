-- Same rows as ClickHouse's tx table; loaded by scripts/run.sh with COPY.
DROP TABLE IF EXISTS tx;

CREATE TABLE tx
(
    id      bigint,
    cents   bigint,
    amt_num numeric(18, 2),
    amt_f64 double precision,
    amt_f32 real
);
