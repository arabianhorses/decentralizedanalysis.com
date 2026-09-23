"""
I have written the scripts by myself however they were looking so ugly so I told the claude polish it and it generated
this script I am sharing original ones too read whichever works for you

Build the data behind decentralizedanalysis.com/dashboards/robinhood_uniswapv3/.

Uniswap v3 on Robinhood Chain. Reads local exports, runs everything in DuckDB,
and writes two files:

  v3_daily_tvl_vol.json   one row per (day, pool): TVL, volume, fees and swap
                          counts by USD size. The top 50 pools by volume are
                          broken out; every other pool is summed into 'others'.
  tvl_snapshot.json       every pool's exact token balances on the last complete
                          day, plus the latest known token prices. The starting
                          point for an incremental TVL run.

TVL method
  balance(token) = running sum of the daily net token flow into the pool
                   (Mint + Swap - Collect + Flash fee), kept as exact integers.
  tvl            = balance0 / 10^decimals0 * price0 + balance1 / 10^decimals1 * price1
  Prices are the last hourly price of each UTC day, carried forward over days
  without one. A leg with no price counts as 0.

Inputs (all in --data-dir)
  swaps_mints_collects_flash_daily_deltas.parquet   pool_address, block_date, am0Delta, am1Delta (integer strings)
  token_prices.parquet                              hourly token prices
  uniswapv3_pools.parquet                           PoolCreated: pool_address, token0, token1, tickSpacing
  token_mapping.parquet                             token_address -> symbol
  vol_fee_nSwaps_v3_2002.json                       daily volume / fees / swap tiers, top 50 + 'others'

Usage
  python3 build_dashboard_data.py --data-dir ./data --out-dir ./data
"""
import argparse
from pathlib import Path

import duckdb

DAILY_DELTAS_FILE = "swaps_mints_collects_flash_daily_deltas.parquet"
TOKEN_PRICES_FILE = "token_prices.parquet"
POOLS_FILE = "uniswapv3_pools.parquet"
TOKEN_MAPPING_FILE = "token_mapping.parquet"
VOLUME_FILE = "vol_fee_nSwaps_v3_2002.json"

DASHBOARD_OUTPUT_FILE = "v3_daily_tvl_vol.json"
SNAPSHOT_OUTPUT_FILE = "tvl_snapshot.json"

# A pool with no activity on or after this date is treated as abandoned: its
# rows stop at its last active day instead of running to the end of the data.
DORMANT_CUTOFF = "2026-08-22"

# Pools whose balance cannot be rebuilt from their logs (tokens reporting
# 2^128-scale amounts, or events with NULL amounts that leave the running
# balance negative). Left in, they overflow or corrupt the totals.
EXCLUDED_POOLS = (
    "0x0e14ed480e1b12391bd46c988c8154442d5cdf25",
    "0x158b81e70ac94e804d74bb88a85e96fa5c4d5049",
    "0x15715eaaad648be2a983847b6cc998b1546a0585",
    "0x174311af8c5704a2e54c15f45ac3e445d4737e82",
    "0x27d9eab51885e4591fe7ee9fea84308457a5eb4c",
    "0x28e839bed642ac1ac2c3d17d9c5426ff72f6cf65",
    "0x365e273b73bd27e8de4e86d3fbde056ff808524b",
    "0x40a46de03ab465cf46e51fc60df993ccb782044f",
    "0x4378a08a044efe62eb7eed0382349a0ac93ff457",
    "0x46204440f30858d890630fddff7d82a32970a51b",
    "0x48023df21197af7b969e38acf85121295753149f",
    "0x48495fab9d3b2a09f2da707741d685db91e252a5",
    "0x4a1e306254172f1ba551d5180be5cd2ee9d50c07",
    "0x555ffa32d1eda8ff99ec0fc17b4236015e76a162",
    "0x5ac3d6b1ca3c638e7aac4255f444acd569ffda00",
    "0x5ec825c00c4b1b799589ba2b37aeaa532fbff843",
    "0x5fb5d433b00ce13c18a0c650c61b212e2f42b9c3",
    "0x666cf31e99c2b33a23fefc6e5771cc50069a2784",
    "0x70098f3b4bea4e88170ae07619586f017f1636f7",
    "0x7bb66adf3cf3bbc49167f8e5953ceff277bb24bf",
    "0x85c1d3f88d8c0322cb75964f333d7e8e5a029006",
    "0x8752c26b9e279fef726dd875574e5f70b0d8088b",
    "0x99d1964702cbb853e70f22cf146bab36b383782c",
    "0xa22b86cf7538f94943fa9ab21ada6a6fa40ce5f9",
    "0xaedbc1bb644ef98de5ece416b3e5dd6586ffef13",
    "0xaefbc8fb41d9efb9f0f8f1bab48a8659e2f37c45",
    "0xaf98668207f86ef72dfcdb4426f815d5ecbc4947",
    "0xeb459fefeae02cf0b2938164a193532625558743",
    "0xf1608ed66ac8972e0398e0fc1b60625736d802f1",
    "0xf6a95ef2d3c4ef23fd1cefe4b6f1e3de30b74d8d",
    "0xfe070c6f27f547e68b2cfee4ae8f4c44aa5d2f9b",
)


def load_inputs(con, data_dir):
    """Expose each input file as a view named after what it holds."""
    views = {
        "daily_deltas": f"read_parquet('{data_dir / DAILY_DELTAS_FILE}')",
        "hourly_token_prices": f"read_parquet('{data_dir / TOKEN_PRICES_FILE}')",
        "pools": f"read_parquet('{data_dir / POOLS_FILE}')",
        "token_mapping": f"read_parquet('{data_dir / TOKEN_MAPPING_FILE}')",
        "daily_volume": f"read_json('{data_dir / VOLUME_FILE}')",
    }
    for name, source in views.items():
        con.sql(f"CREATE OR REPLACE VIEW {name} AS SELECT * FROM {source}")


def build_pool_balances(con):
    """pool_balances: exact token balances for every pool on every day of its life.

    Balances are HUGEINT running sums of the daily deltas. Days without activity
    carry the previous balance forward. A pool that went dormant before
    DORMANT_CUTOFF stops at its last active day; every other pool runs to the
    last day in the data.
    """
    excluded = ", ".join(f"'{p}'" for p in EXCLUDED_POOLS)
    con.sql(f"""
    CREATE OR REPLACE TABLE pool_balances AS
    WITH
    running_balances AS (
        SELECT
            pool_address
          , block_date
          , SUM(CAST(am0Delta AS HUGEINT)) OVER (PARTITION BY pool_address ORDER BY block_date) AS balance0
          , SUM(CAST(am1Delta AS HUGEINT)) OVER (PARTITION BY pool_address ORDER BY block_date) AS balance1
        FROM daily_deltas
        WHERE pool_address NOT IN ({excluded})
    )
    , pool_lifetimes AS (
        SELECT
            pool_address
          , first_active_day
          , CASE WHEN last_active_day < DATE '{DORMANT_CUTOFF}' THEN last_active_day
                 ELSE last_data_day END AS last_day
        FROM (
            SELECT
                pool_address
              , MIN(block_date)              AS first_active_day
              , MAX(block_date)              AS last_active_day
              , MAX(MAX(block_date)) OVER () AS last_data_day
            FROM running_balances
            GROUP BY pool_address
        )
    )
    , pool_days AS (
        SELECT
            pool_address
          , UNNEST(generate_series(first_active_day, last_day, INTERVAL 1 DAY))::DATE AS day
        FROM pool_lifetimes
    )
    SELECT
        d.pool_address
      , d.day
      , COALESCE(b.balance0, LAG(b.balance0 IGNORE NULLS) OVER w) AS balance0
      , COALESCE(b.balance1, LAG(b.balance1 IGNORE NULLS) OVER w) AS balance1
    FROM pool_days d
    LEFT JOIN running_balances b
           ON b.pool_address = d.pool_address
          AND b.block_date   = d.day
    WINDOW w AS (PARTITION BY d.pool_address ORDER BY d.day)
    """)


def build_daily_token_prices(con):
    """daily_token_prices: each token's last hourly price of each UTC day."""
    con.sql("""
    CREATE OR REPLACE TABLE daily_token_prices AS
    SELECT
        (hour AT TIME ZONE 'UTC')::DATE AS day
      , tokenAddress
      , tokenDecimals
      , price
    FROM hourly_token_prices
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY tokenAddress, (hour AT TIME ZONE 'UTC')::DATE
        ORDER BY hour DESC
    ) = 1
    """)


def write_tvl_snapshot(con, out_path):
    """Exact balances on the day before the last data day, with the latest prices.

    The last day may be partial, so the snapshot sits one day earlier. Balances
    are written as strings so they survive JSON exactly; read them back with
    CAST(... AS HUGEINT). Only pools with at least one priced token are kept.
    """
    con.sql(f"""
    COPY (
        WITH
        snapshot AS (
            SELECT MAX(day) - 1 AS snapshot_date FROM pool_balances
        )
        , latest_prices AS (
            SELECT tokenAddress, tokenDecimals, price
            FROM daily_token_prices
            WHERE day <= (SELECT snapshot_date FROM snapshot)
            QUALIFY ROW_NUMBER() OVER (PARTITION BY tokenAddress ORDER BY day DESC) = 1
        )
        SELECT
            b.pool_address
          , b.day                          AS snapshot_date
          , CAST(b.balance0 AS VARCHAR)    AS cumulativeAmount0
          , CAST(b.balance1 AS VARCHAR)    AS cumulativeAmount1
          , p.token0                       AS tk0Address
          , price0.tokenDecimals           AS tk0Decimals
          , price0.price                   AS tk0Price
          , p.token1                       AS tk1Address
          , price1.tokenDecimals           AS tk1Decimals
          , price1.price                   AS tk1Price
        FROM pool_balances b
        LEFT JOIN pools p              ON p.pool_address = b.pool_address
        LEFT JOIN latest_prices price0 ON price0.tokenAddress = p.token0
        LEFT JOIN latest_prices price1 ON price1.tokenAddress = p.token1
        WHERE b.day = (SELECT snapshot_date FROM snapshot)
          AND (price0.tokenDecimals IS NOT NULL OR price1.tokenDecimals IS NOT NULL)
        ORDER BY b.pool_address
    ) TO '{out_path}' (FORMAT json, ARRAY true)
    """)


def build_pool_names(con):
    """named_pools: 'SYMBOL0/SYMBOL1 CL-<tickSpacing>' for pools with at least one known token.

    Pools where neither token is in token_mapping are left out, and so are left
    out of TVL.
    """
    con.sql("""
    CREATE OR REPLACE TABLE named_pools AS
    SELECT
        p.pool_address
      , CONCAT(COALESCE(t0.symbol, p.token0), '/', COALESCE(t1.symbol, p.token1), ' CL-', p.tickSpacing) AS pool_name
      , p.token0
      , p.token1
    FROM pools p
    LEFT JOIN token_mapping t0 ON t0.token_address = p.token0
    LEFT JOIN token_mapping t1 ON t1.token_address = p.token1
    WHERE t0.symbol IS NOT NULL OR t1.symbol IS NOT NULL
    """)


def build_pool_tvl(con):
    """pool_tvl: USD TVL per pool per day, floored to whole dollars.

    Decimals and price are carried forward per pool over days with no price.
    """
    con.sql("""
    CREATE OR REPLACE TABLE pool_tvl AS
    WITH
    priced_balances AS (
        SELECT
            b.day
          , b.pool_address
          , b.balance0
          , b.balance1
          , COALESCE(price0.tokenDecimals, LAG(price0.tokenDecimals IGNORE NULLS) OVER w) AS decimals0
          , COALESCE(price0.price,         LAG(price0.price         IGNORE NULLS) OVER w) AS price0
          , COALESCE(price1.tokenDecimals, LAG(price1.tokenDecimals IGNORE NULLS) OVER w) AS decimals1
          , COALESCE(price1.price,         LAG(price1.price         IGNORE NULLS) OVER w) AS price1
        FROM pool_balances b
        JOIN named_pools n ON n.pool_address = b.pool_address
        LEFT JOIN daily_token_prices price0 ON price0.tokenAddress = n.token0 AND price0.day = b.day
        LEFT JOIN daily_token_prices price1 ON price1.tokenAddress = n.token1 AND price1.day = b.day
        WINDOW w AS (PARTITION BY b.pool_address ORDER BY b.day)
    )
    SELECT
        day
      , pool_address
      , FLOOR(
            COALESCE((balance0 / POW(10, decimals0)) * price0, 0)
          + COALESCE((balance1 / POW(10, decimals1)) * price1, 0)
        ) AS tvl
    FROM priced_balances
    """)


def build_dashboard_rows(con):
    """TVL rolled up to the volume file's top 50 + 'others', joined to volume and swap counts."""
    con.sql("""
    CREATE OR REPLACE TABLE top_pools AS
    SELECT poolAddress, poolName
    FROM daily_volume
    WHERE poolAddress != 'others'
    QUALIFY ROW_NUMBER() OVER (PARTITION BY poolAddress ORDER BY day_) = 1
    """)
    return con.sql("""
    WITH
    tvl_by_top_pool AS (
        SELECT
            t.day
          , COALESCE(top.poolAddress, 'others') AS poolAddress
          , COALESCE(top.poolName,    'others') AS poolName
          , SUM(t.tvl)                          AS tvl
        FROM pool_tvl t
        LEFT JOIN top_pools top ON top.poolAddress = t.pool_address
        GROUP BY 1, 2, 3
    )
    SELECT
        t.day
      , t.poolAddress
      , t.poolName
      , t.tvl
      , v.dailyVol
      , v.dailyFee
      , v.nSwaps_0_10
      , v.nSwaps_10_100
      , v.nSwaps_100_1k
      , v.nSwaps_1k_10k
      , v.nSwaps_10k_100k
      , v.nSwaps_100k_1m
      , v.nSwaps_1m_
    FROM tvl_by_top_pool t
    LEFT JOIN daily_volume v
           ON v.day_::DATE  = t.day
          AND v.poolAddress = t.poolAddress
    ORDER BY t.day, v.dailyVol DESC, t.poolAddress
    """).df()


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0].strip())
    parser.add_argument("--data-dir", type=Path, default=Path("data"), help="folder holding the input files")
    parser.add_argument("--out-dir", type=Path, default=Path("data"), help="folder to write the two JSON files to")
    args = parser.parse_args()
    args.out_dir.mkdir(parents=True, exist_ok=True)

    con = duckdb.connect()
    con.sql("SET TimeZone = 'UTC'")

    load_inputs(con, args.data_dir)
    build_pool_balances(con)
    build_daily_token_prices(con)
    write_tvl_snapshot(con, args.out_dir / SNAPSHOT_OUTPUT_FILE)
    build_pool_names(con)
    build_pool_tvl(con)

    rows = build_dashboard_rows(con)
    rows.to_json(
        args.out_dir / DASHBOARD_OUTPUT_FILE,
        orient="records", date_format="iso", date_unit="s", indent=2,
    )
    print(f"wrote {len(rows):,} rows -> {args.out_dir / DASHBOARD_OUTPUT_FILE}")
    print(f"wrote snapshot       -> {args.out_dir / SNAPSHOT_OUTPUT_FILE}")


if __name__ == "__main__":
    main()
