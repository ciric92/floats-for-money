#!/usr/bin/env bash
# Runs every experiment and prints a Markdown report (also saved to results/).
#
#   ./scripts/run.sh                 # full run
#   RUNS_CH=10 RUNS_PG=5 ./scripts/run.sh   # quicker
#   KEEP=1 ./scripts/run.sh          # leave the containers running afterwards
set -euo pipefail
cd "$(dirname "$0")/.."

RUNS_CH=${RUNS_CH:-50}     # repeated SUMs in ClickHouse
RUNS_PG=${RUNS_PG:-20}     # repeated SUMs in Postgres
PG_WORKERS=${PG_WORKERS:-4} # max_parallel_workers_per_gather
EXACT="10000885101.33"     # sum of tx.cents / 100, checked below

ch() { docker compose exec -T clickhouse clickhouse-client "$@"; }
pg() { docker compose exec -T postgres psql -U postgres -qAtX -v ON_ERROR_STOP=1 "$@"; }
pg_par() { pg -c "SET max_parallel_workers_per_gather = $PG_WORKERS" -c "$1"; }
log() { echo "$*" >&2; }
# Collapse repeated output lines into "N× value", one per line.
tally() { sort | uniq -c | awk '{printf "%s× %s<br>", $1, $2}' | sed 's/<br>$//'; }
distinct() { sort -u | wc -l | tr -d ' '; }

mkdir -p results
OUT="results/$(date +%Y-%m-%d).md"
exec > >(tee "$OUT")

log "Starting containers…"
docker compose up -d --wait >&2
[ "${KEEP:-0}" = 1 ] || trap 'docker compose down -v >&2' EXIT

log "Generating 20M transactions and 100k deals in ClickHouse…"
ch --multiquery < sql/clickhouse/setup.sql

log "Copying transactions into Postgres…"
pg < sql/postgres/setup.sql
ch -q "SELECT id, cents, amt_dec, toString(amt_f64), toString(amt_f32) FROM tx FORMAT CSV" \
  | pg -c "\copy tx FROM STDIN CSV"
pg -c "VACUUM ANALYZE tx" >/dev/null

truth_ch=$(ch -q "SELECT toString(sum(cents) / 100) FROM tx")
truth_pg=$(pg -c "SELECT sum(cents) / 100.0 FROM tx")
log "Exact total: ClickHouse $truth_ch, Postgres $truth_pg"
[ "$truth_ch" = "$EXACT" ] || { log "Unexpected ClickHouse total"; exit 1; }

cat <<EOF
# Results, $(date +%Y-%m-%d)

- Machine: $(uname -sm), $(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu) cores
- ClickHouse $(ch -q "SELECT version()"), Postgres $(pg -c "SHOW server_version")
- 20,000,000 transactions, \$0.01 to \$999.99. Exact total: **\$$EXACT**

## 1. Same SUM, run again and again

| Engine and type | Results (count × value) | Distinct |
| --- | --- | --- |
EOF

log "SUM in ClickHouse, $RUNS_CH runs…"
for col in amt_dec amt_f64 amt_f32; do
  vals=$(for _ in $(seq "$RUNS_CH"); do ch -q "SELECT toString(sum($col)) FROM tx"; done)
  echo "| ClickHouse \`$col\` | $(echo "$vals" | tally) | $(echo "$vals" | distinct) of $RUNS_CH |"
done

log "SUM in Postgres ($PG_WORKERS workers), $RUNS_PG runs…"
# ::text prints the shortest exact representation (extra_float_digits = 1);
# casting a float to numeric would round to 15 digits and hide the differences.
for col in amt_num amt_f64 amt_f32; do
  cast=$([ "$col" = amt_f32 ] && echo "::float8::text" || echo "::text")
  vals=$(for _ in $(seq "$RUNS_PG"); do pg_par "SELECT sum($col)$cast FROM tx"; done)
  echo "| Postgres \`$col\` | $(echo "$vals" | tally) | $(echo "$vals" | distinct) of $RUNS_PG |"
done

cat <<EOF

Columns: \`amt_dec\`/\`amt_num\` = exact decimal, \`amt_f64\` = Float64 / double precision,
\`amt_f32\` = Float32 / real. Postgres \`SUM(real)\` also accumulates in single precision.

## 2. Single-threaded, for comparison

| Engine | Float64 SUM, 3 runs |
| --- | --- |
EOF
log "Single-threaded runs…"
echo "| ClickHouse, max_threads = 1 | $(for _ in 1 2 3; do ch -q "SELECT toString(sum(amt_f64)) FROM tx SETTINGS max_threads = 1"; done | tally) |"
echo "| Postgres, no parallel workers | $(for _ in 1 2 3; do pg -c "SET max_parallel_workers_per_gather = 0" -c "SELECT sum(amt_f64)::text FROM tx"; done | tally) |"

log "Equality checks…"
cat <<EOF

## 3. Equality: float arithmetic vs decimal arithmetic (Postgres, 20M rows)

| Check | Rows where float ≠ decimal |
| --- | --- |
EOF
pg -c "SELECT count(*) FILTER (WHERE amt_f64 * 3 <> (amt_num * 3)::float8),
              count(*) FILTER (WHERE amt_f64 + 0.1 + 0.2 <> (amt_num + 0.3)::float8),
              count(*) FROM tx" \
  | awk -F'|' '{printf "| amount × 3 | %d (%.1f%%) |\n| amount + 0.1 + 0.2 | %d (%.1f%%) |\n", $1, 100*$1/$3, $2, 100*$2/$3}'

log "Float32 deals…"
cat <<EOF

## 4. Float32 for B2B deal amounts (ClickHouse, 100k deals, \$1k to \$5M)

| Deals not stored to the cent | Worst error per deal | Total (exact → Float32) |
| --- | --- | --- |
EOF
ch -q "SELECT countIf(toInt64(round(amt_f32 * 100)) != cents) AS bad, count() AS n,
              max(abs(toFloat64(amt_dec) - amt_f32)) AS worst,
              toString(sum(amt_dec)) AS exact, toString(sum(amt_f32)) AS f32
       FROM deals FORMAT TSV" \
  | awk -F'\t' '{printf "| %d of %d (%.1f%%) | $%.2f | $%s → $%s |\n", $1, $2, 100*$1/$2, $3, $4, $5}'
echo
echo "Example: \$$(ch -q "SELECT toString(amt_dec) FROM deals ORDER BY cents DESC LIMIT 1") is stored as \$$(ch -q "SELECT toString(amt_f32) FROM deals ORDER BY cents DESC LIMIT 1")."

log "Attribution splits…"
cat <<EOF

## 5. Attribution: split each deal into N equal Float64 shares, add them back

| Touchpoints | Deals where the shares sum exactly to the deal |
| --- | --- |
EOF
ch -q "SELECT n, countIf(arraySum(arrayMap(i -> amt_f64 * (1 / n), range(n))) = amt_f64) AS ok, count() AS total
       FROM deals ARRAY JOIN [3, 7, 12] AS n GROUP BY n ORDER BY n FORMAT TSV" \
  | awk -F'\t' '{printf "| %d | %.1f%% |\n", $1, 100*$2/$3}'

log "Timing…"
cat <<EOF

## 6. Speed of a bare SUM over 20M rows (median of 5, warm cache)

| Engine | Exact decimal | Float64 | Float32 | Integer cents |
| --- | --- | --- | --- | --- |
EOF
median() { sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'; }
row="| ClickHouse"
for col in amt_dec amt_f64 amt_f32 cents; do
  ch -q "SELECT sum($col) FROM tx FORMAT Null" # warm-up
  ms=$(for _ in 1 2 3 4 5; do ch --time -q "SELECT sum($col) FROM tx FORMAT Null" 2>&1; done | awk '{print $1*1000}' | median)
  row="$row | $(printf '%.0f' "$ms") ms"
done
echo "$row |"
row="| Postgres ($PG_WORKERS workers)"
for col in amt_num amt_f64 amt_f32 cents; do
  pg_par "SELECT sum($col) FROM tx" >/dev/null # warm-up
  ms=$(for _ in 1 2 3 4 5; do
         pg -c "SET max_parallel_workers_per_gather = $PG_WORKERS" -c '\timing on' -c "SELECT sum($col) FROM tx" \
           | awk '/^Time:/ {print $2}'
       done | median)
  row="$row | $(printf '%.0f' "$ms") ms"
done
echo "$row |"

cat <<EOF

## 7. Fixed-point ad money: exact, to the wrong unit

EOF
python3 scripts/adserver_rounding.py

log "Done. Report saved to $OUT"
