-- Every amount is generated as integer cents (the ground truth), then stored
-- three ways: exact decimal, Float64 and Float32. Data is deterministic
-- (cityHash64 of the row number), so every run sees the same rows.

DROP TABLE IF EXISTS tx;
DROP TABLE IF EXISTS deals;

-- 20M transactions, $0.01 .. $999.99
CREATE TABLE tx
(
    id      UInt64,
    cents   Int64,
    amt_dec Decimal(18, 2),
    amt_f64 Float64,
    amt_f32 Float32
)
ENGINE = MergeTree ORDER BY id;

-- Inserted in two batches so the table has several parts, as it would in production.
INSERT INTO tx
SELECT number, c, toDecimal64(c, 2) / 100, c / 100, toFloat32(c / 100)
FROM (SELECT number, toInt64(1 + cityHash64(number) % 99999) AS c FROM numbers(10000000));

INSERT INTO tx
SELECT number + 10000000, c, toDecimal64(c, 2) / 100, c / 100, toFloat32(c / 100)
FROM (SELECT number, toInt64(1 + cityHash64(number, 7) % 99999) AS c FROM numbers(10000000));

-- 100k B2B deals, $1,000 .. $5,000,000
CREATE TABLE deals
(
    id      UInt64,
    cents   Int64,
    amt_dec Decimal(18, 2),
    amt_f64 Float64,
    amt_f32 Float32
)
ENGINE = MergeTree ORDER BY id;

INSERT INTO deals
SELECT number, c, toDecimal64(c, 2) / 100, c / 100, toFloat32(c / 100)
FROM (SELECT number, toInt64(100000 + cityHash64(number, 3) % 499900000) AS c FROM numbers(100000));
