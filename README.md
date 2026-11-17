# Floats for money: a benchmark

Companion repo for the article *Don't Use Floats for Money (and Then It Breaks Anyway)*. It
measures what floating-point money actually does to analytics numbers in ClickHouse and
Postgres. It also shows how a fixed-point type that is "done right" still breaks when prices
get small enough.

One command, two pinned database containers, deterministic data. Your timings will differ, but
the correctness results should match.

## What it measures

| # | Question | Where |
| --- | --- | --- |
| 1 | Does the same `SUM` over the same 20M rows give the same answer every time? | ClickHouse, Postgres |
| 2 | Does it become stable with a single thread? | ClickHouse, Postgres |
| 3 | How often does float arithmetic disagree with decimal arithmetic, row by row? | Postgres |
| 4 | How many B2B deal amounts ($1k–$5M) survive being stored as `Float32`? | ClickHouse |
| 5 | Split a deal into N equal attribution shares: do they add back up to the deal? | ClickHouse |
| 6 | What does an exact decimal cost in speed? | ClickHouse, Postgres |
| 7 | Fixed-point ad money: what do 5 or 6 decimal places do to margins at low CPMs? | Python, stdlib only |

## Run it

Requirements: Docker with Compose v2, Bash and Python 3. About 1.5 GB of free memory, and a
few minutes.

```bash
./scripts/run.sh
```

It starts Postgres 17.12 and ClickHouse 25.7, generates the data, runs every experiment,
prints a Markdown report and saves it to `results/<date>.md`. The containers and their data
are removed when it finishes.

Options, as environment variables:

| Variable | Default | Meaning |
| --- | --- | --- |
| `RUNS_CH` | 50 | How many times to repeat each `SUM` in ClickHouse |
| `RUNS_PG` | 20 | How many times to repeat each `SUM` in Postgres |
| `PG_WORKERS` | 4 | Postgres `max_parallel_workers_per_gather` |
| `KEEP` | 0 | `1` leaves the containers running so you can poke at the tables |

With `KEEP=1`, open a client with `docker compose exec clickhouse clickhouse-client` or
`docker compose exec postgres psql -U postgres`, and clean up with `docker compose down -v`.

The ad server table on its own needs no database:

```bash
python3 scripts/adserver_rounding.py        # 20% margin
python3 scripts/adserver_rounding.py 0.35   # any other margin
```

## The data

Every amount is generated as **integer cents**, which is the ground truth. It's then stored
three ways in the same row: an exact decimal (`Decimal(18,2)` / `numeric(18,2)`), a 64-bit float
(`Float64` / `double precision`) and a 32-bit float (`Float32` / `real`). Rows come from
`cityHash64(row number)`, so every run on every machine gets identical data.

| Table | Rows | Amounts | Exact total |
| --- | --- | --- | --- |
| `tx` | 20,000,000 | $0.01 to $999.99 | $10,000,885,101.33 |
| `deals` | 100,000 | $1,000 to $5,000,000 | $250,426,988,387.45 |

`tx` is generated in ClickHouse in two inserts, so the table has several parts, as a real
table would. It's then streamed into Postgres with `COPY`.

## Results

Full report from the reference run: [`results/2026-11-18.md`](results/2026-11-18.md)
(Apple Silicon laptop, 12 cores, ClickHouse 25.7.8, Postgres 17.12, 4 parallel workers).

| Finding | Number |
| --- | --- |
| Exact decimal `SUM`, repeated | Same answer every time in both engines (50 of 50, 20 of 20) |
| ClickHouse `Float64` `SUM`, repeated | 5 different totals in 50 runs, all within $0.00001 |
| Postgres `double precision` `SUM`, repeated | 18 different totals in 20 runs, all within $0.0003 |
| Same queries, single-threaded | Stable again, but still not equal to the exact total |
| Postgres `real` `SUM` | Off by **$4.28M to $4.39M** (0.04%), different on 18 of 20 runs |
| Float arithmetic ≠ decimal arithmetic | 29.5% of rows for `amount × 3`, 46.3% for `amount + 0.1 + 0.2` |
| `Float32` deal amounts ($1k–$5M) | 88.7% not stored to the cent, worst off by $0.25 |
| Deal split into 3 / 7 / 12 equal `Float64` shares | Adds back exactly in 70.0% / 54.9% / 35.8% of deals |
| Bare `SUM` speed, decimal vs `Float64` | ClickHouse 18 ms vs 13 ms; Postgres 226 ms vs 180 ms |
| 20% margin at $0.065 CPM, 5 decimal places | Stored 23.1% too low; at $0.013 CPM it rounds to zero |

Every `Float64` total rounds to the right cent. The problem isn't the size of the error. It's
that the same query over the same data gives a different answer each time, which breaks
equality checks, snapshot tests and "did this number change?" alerts.

## Layout

```
docker-compose.yml            pinned Postgres and ClickHouse
sql/clickhouse/setup.sql      data generation (tx, deals)
sql/postgres/setup.sql        Postgres table definition
scripts/run.sh                runs everything, writes results/<date>.md
scripts/adserver_rounding.py  fixed-point margin table
```

## Caveats

- **Run-to-run differences depend on parallelism.** How many distinct `Float64` totals you
  see depends on core count, parallel workers and how the table is split into parts. The
  *existence* of differences is the finding, not their exact count.
- **Timings are a worst case for decimals.** A bare `SUM` with nothing else in the query is
  where a decimal type costs the most. They're medians of 5 warm runs on one laptop, not a
  tuned benchmark.
- **ClickHouse `sum(Float32)` adds up in Float64,** so its error comes from storage alone.
  Postgres `sum(real)` returns `real` and adds up in single precision, which is why its error
  is so much larger.
- **Decimals don't make 1/3 exact.** The attribution experiment shows that floats hide the
  leftover; a decimal type makes you decide where the leftover cent goes.

## Licence

[MIT](LICENSE)
