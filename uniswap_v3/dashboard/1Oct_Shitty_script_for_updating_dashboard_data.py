import pandas as pd 
import duckdb 
from google.cloud import bigquery

current_daily_tvl_vol_data = pd.read_json("/Users/oguzkarabulut/Desktop/decentralizedanalysis.com/the_site/robinhood_uniswap_dashboard/30September/v3_daily_tvl_vol.json") 
"""
day                2026-09-17T00:00:00
poolAddress                     others
poolName                        others
tvl                           74958116
dailyVol                    69485594.0
dailyFee                     328263.59
nSwaps_0_10                   151995.0
nSwaps_10_100                 129120.0
nSwaps_100_1k                 114303.0
nSwaps_1k_10k                  13135.0
nSwaps_10k_100k                  105.0
nSwaps_100k_1m                     0.0
nSwaps_1m_                         0.0
"""
top50_poolAddress_poolName = duckdb.sql(f"""
SELECT poolAddress, poolName FROM current_daily_tvl_vol_data
WHERE poolName != 'others'
AND day = (SELECT  max(day) FROM current_daily_tvl_vol_data) -- instead this qualify row ? 
""")

current_tvl_snapshot = pd.read_json("/Users/oguzkarabulut/Desktop/decentralizedanalysis.com/the_site/robinhood_uniswap_dashboard/30September/tvl_snapshot_all_pools.json", dtype={"cumulativeAmount0": str, "cumulativeAmount1": str})

current_tvl_snapshot_date = duckdb.sql("""
SELECT MIN(snapshot_date)::DATE FROM current_tvl_snapshot
""").fetchone()[0]

bq_client = bigquery.Client(project="decentralizedanalysis")

vol_fee_related_data = bq_client.query(f"""
WITH swaps_and_token_info AS (
SELECT 
swa.block_date AS day
, swa.pool_address
, swa.amount0 , pr0.tokenDecimals AS tk0D, pr0.price AS tk0P
, swa.amount1 , pr1.tokenDecimals AS tk1D, pr1.price AS tk1P
, pc.fee/POW(10,6) AS feeMultiplier
FROM `decentralizedanalysis.robinhood.robinhood_uniswapv3_swaps` swa
INNER JOIN `decentralizedanalysis.robinhood.robinhood_uniswapv3_pools` pc ON swa.pool_address = pc.pool_address
LEFT JOIN `decentralizedanalysis.robinhood.robinhood_token_prices` pr0 ON pc.token0 = pr0.tokenAddress AND swa.block_hour = pr0.hour
LEFT JOIN `decentralizedanalysis.robinhood.robinhood_token_prices` pr1 ON pc.token1 = pr1.tokenAddress AND swa.block_hour = pr1.hour
WHERE swa.block_date > DATE '{current_tvl_snapshot_date}'
)
, swaps_with_vol AS (
SELECT 
day
, pool_address, feeMultiplier
, CASE 
    WHEN amount0 > 0 AND tk0D IS NOT NULL AND tk1D IS NOT NULL THEN (amount0/POW(10,tk0D)) * tk0P 
    WHEN amount1 > 0 AND tk0D IS NOT NULL AND tk1D IS NOT NULL THEN (amount1/POW(10,tk1D)) * tk1P 
    WHEN tk0D IS NOT NULL AND tk1D IS NULL THEN (ABS(amount0)/POW(10,tk0D)) * tk0P 
    WHEN tk0D IS  NULL AND tk1D IS NOT NULL THEN (ABS(amount1)/POW(10,tk1D)) * tk1P 
 END AS volume
FROM swaps_and_token_info
)


SELECT 
day, pool_address, feeMultiplier
, ROUND(SUM(volume), 1) AS dailyVol
, ROUND((SUM(volume) * feeMultiplier ), 2) AS dailyFee
, COUNTIF(volume > 0 AND volume <= 10) AS nSwaps_0_10
, COUNTIF(volume > 10 AND volume <= 100) AS nSwaps_10_100
, COUNTIF(volume > 100 AND volume <= 1000) AS nSwaps_100_1k
, COUNTIF(volume > 1000 AND volume <= 10000) AS nSwaps_1k_10k
, COUNTIF(volume > 10000 AND volume <= 100000) AS nSwaps_10k_100k
, COUNTIF(volume > 100000 AND volume <= 1000000) AS nSwaps_100k_1m
, COUNTIF(volume > 1000000) AS nSwaps_1m_
, COUNT(*) AS swaps
, COUNTIF(volume IS NOT NULL) AS priced_swaps
FROM swaps_with_vol
GROUP BY 1, 2, 3
""").to_dataframe(create_bqstorage_client=False)

vol_fee_related_data["day"] = pd.to_datetime(vol_fee_related_data["day"])
daily_vol_top50 = duckdb.sql("""
SELECT
vfrd.day
, COALESCE(top.poolAddress, 'others') AS poolAddress
, COALESCE(top.poolName, 'others') AS poolName
, SUM(vfrd.dailyVol) AS dailyVol
, SUM(vfrd.dailyFee) AS dailyFee
, SUM(vfrd.nSwaps_0_10) AS nSwaps_0_10
, SUM(vfrd.nSwaps_10_100) AS nSwaps_10_100
, SUM(vfrd.nSwaps_100_1k) AS nSwaps_100_1k
, SUM(vfrd.nSwaps_1k_10k) AS nSwaps_1k_10k
, SUM(vfrd.nSwaps_10k_100k) AS nSwaps_10k_100k
, SUM(vfrd.nSwaps_100k_1m) AS nSwaps_100k_1m
, SUM(vfrd.nSwaps_1m_) AS nSwaps_1m_
FROM vol_fee_related_data vfrd
LEFT JOIN top50_poolAddress_poolName top ON vfrd.pool_address = top.poolAddress
GROUP BY 1, 2, 3
""").df()


token_deltas_after_snapshot = bq_client.query(f"""
WITH bad_pools AS (
  SELECT * FROM UNNEST([
    '0x0e14ed480e1b12391bd46c988c8154442d5cdf25','0x15715eaaad648be2a983847b6cc998b1546a0585',
    '0x158b81e70ac94e804d74bb88a85e96fa5c4d5049','0x174311af8c5704a2e54c15f45ac3e445d4737e82',
    '0x27d9eab51885e4591fe7ee9fea84308457a5eb4c','0x28e839bed642ac1ac2c3d17d9c5426ff72f6cf65',
    '0x365e273b73bd27e8de4e86d3fbde056ff808524b','0x40a46de03ab465cf46e51fc60df993ccb782044f',
    '0x4378a08a044efe62eb7eed0382349a0ac93ff457','0x46204440f30858d890630fddff7d82a32970a51b',
    '0x48023df21197af7b969e38acf85121295753149f','0x48495fab9d3b2a09f2da707741d685db91e252a5',
    '0x4a1e306254172f1ba551d5180be5cd2ee9d50c07','0x555ffa32d1eda8ff99ec0fc17b4236015e76a162',
    '0x5ac3d6b1ca3c638e7aac4255f444acd569ffda00','0x5ec825c00c4b1b799589ba2b37aeaa532fbff843',
    '0x5fb5d433b00ce13c18a0c650c61b212e2f42b9c3','0x666cf31e99c2b33a23fefc6e5771cc50069a2784',
    '0x70098f3b4bea4e88170ae07619586f017f1636f7','0x7bb66adf3cf3bbc49167f8e5953ceff277bb24bf',
    '0x85c1d3f88d8c0322cb75964f333d7e8e5a029006','0x8752c26b9e279fef726dd875574e5f70b0d8088b',
    '0x99d1964702cbb853e70f22cf146bab36b383782c','0xa22b86cf7538f94943fa9ab21ada6a6fa40ce5f9',
    '0xaedbc1bb644ef98de5ece416b3e5dd6586ffef13','0xaefbc8fb41d9efb9f0f8f1bab48a8659e2f37c45',
    '0xaf98668207f86ef72dfcdb4426f815d5ecbc4947','0xeb459fefeae02cf0b2938164a193532625558743',
    '0xf1608ed66ac8972e0398e0fc1b60625736d802f1','0xf6a95ef2d3c4ef23fd1cefe4b6f1e3de30b74d8d',
    '0xfe070c6f27f547e68b2cfee4ae8f4c44aa5d2f9b'
  ]) AS pool_address
)

, token_deltas AS (
SELECT block_date AS day, pool_address
     , CAST(SUM(am0Delta) AS STRING) AS am0Delta
     , CAST(SUM(am1Delta) AS STRING) AS am1Delta
FROM (
  -- swaps: amounts are already pool-side (+ = into the pool)
  SELECT block_date, pool_address, SUM(amount0) AS am0Delta, SUM(amount1) AS am1Delta
  FROM `decentralizedanalysis.robinhood.robinhood_uniswapv3_swaps`
  WHERE block_date > DATE '{current_tvl_snapshot_date}'
    AND pool_address NOT IN (SELECT pool_address FROM bad_pools)
  GROUP BY 1, 2

  UNION ALL
  -- mints: tokens go in. Burns move nothing, they only credit tokensOwed
  SELECT block_date, pool_address, SUM(amount0), SUM(amount1)
  FROM `decentralizedanalysis.robinhood.robinhood_uniswapv3_liquidity_movements`
  WHERE block_date > DATE '{current_tvl_snapshot_date}' AND liquidityDelta > 0
    AND pool_address NOT IN (SELECT pool_address FROM bad_pools)
  GROUP BY 1, 2

  UNION ALL
  -- collects: tokens actually leave here, so negate
  SELECT block_date, pool_address, -SUM(amount0), -SUM(amount1)
  FROM `decentralizedanalysis.robinhood.robinhood_uniswapv3_collects`
  WHERE block_date > DATE '{current_tvl_snapshot_date}'
    AND pool_address NOT IN (SELECT pool_address FROM bad_pools)
  GROUP BY 1, 2

  UNION ALL
  -- flash: paid is the fee the pool kept, add it unnegated
  SELECT block_date, pool_address, SUM(paid0), SUM(paid1)
  FROM `decentralizedanalysis.robinhood.robinhood_uniswapv3_flash`
  WHERE block_date > DATE '{current_tvl_snapshot_date}'
    AND pool_address NOT IN (SELECT pool_address FROM bad_pools)
  GROUP BY 1, 2

)
GROUP BY 1, 2
)
SELECT 
td.day, td.pool_address
, pc.token0 AS tk0Address, td.am0Delta
, pc.token1 AS tk1Address, td.am1Delta
FROM token_deltas td
INNER JOIN `decentralizedanalysis.robinhood.robinhood_uniswapv3_pools` pc ON td.pool_address = pc.pool_address
""").to_dataframe(create_bqstorage_client=False)

token_deltas_after_snapshot["day"] = pd.to_datetime(token_deltas_after_snapshot["day"])

print(token_deltas_after_snapshot.iloc[0]) 

daily_prices = bq_client.query(f"""
SELECT 
DATE(hour) AS day
, tokenAddress, tokenDecimals, price
FROM `decentralizedanalysis.robinhood.robinhood_token_prices`
WHERE hour > TIMESTAMP '{current_tvl_snapshot_date}'
QUALIFY ROW_NUMBER() OVER(PARTITION BY tokenAddress, DATE(hour) ORDER BY hour DESC) = 1
""").to_dataframe(create_bqstorage_client=False)

daily_prices["day"] = pd.to_datetime(daily_prices["day"])

print(daily_prices.iloc[0])

existing_pools_in_snapshot = duckdb.sql(f"""
WITH
pools AS (
SELECT pool_address, tk0Address, tk1Address FROM current_tvl_snapshot
UNION
SELECT pool_address, tk0Address, tk1Address FROM token_deltas_after_snapshot
)
, days AS (
SELECT UNNEST(generate_series(TIMESTAMP '{current_tvl_snapshot_date}' + INTERVAL 1 DAY
                            , (SELECT MAX(day) FROM token_deltas_after_snapshot)
                            , INTERVAL 1 DAY)) AS day
)
, pool_day_grid AS (
SELECT p.pool_address, p.tk0Address, p.tk1Address, d.day
FROM pools p CROSS JOIN days d
)
, current_snapshot_data_merged_with_post_snapshot_data AS (
SELECT
cts.snapshot_date::TIMESTAMP AS day, cts.pool_address
, cts.cumulativeAmount0 AS am0Delta --just manipulating it is cumulative amount upto snapshotdate
, cts.tk0Address, cts.tk0Decimals, cts.tk0Price
, cts.cumulativeAmount1 AS am1Delta
, cts.tk1Address, cts.tk1Decimals, cts.tk1Price
FROM current_tvl_snapshot cts

UNION ALL

SELECT
g.day, g.pool_address
, tdas.am0Delta
, g.tk0Address, dp0.tokenDecimals AS tk0Decimals, dp0.price AS tk0Price
, tdas.am1Delta
, g.tk1Address, dp1.tokenDecimals AS tk1Decimals, dp1.price AS tk1Price
FROM pool_day_grid g
LEFT JOIN token_deltas_after_snapshot tdas ON tdas.pool_address = g.pool_address AND tdas.day = g.day
LEFT JOIN daily_prices dp0 ON dp0.tokenAddress = g.tk0Address AND dp0.day = g.day
LEFT JOIN daily_prices dp1 ON dp1.tokenAddress = g.tk1Address AND dp1.day = g.day
)

, full_info AS (
SELECT
day, pool_address
, tk0Address
, SUM(COALESCE(am0Delta::HUGEINT, 0)) OVER (PARTITION BY pool_address ORDER BY day) AS cumulativeAmount0
, LAST_VALUE(tk0Decimals IGNORE NULLS) OVER (PARTITION BY pool_address ORDER BY day
                                            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS tk0Decimals
, LAST_VALUE(tk0Price IGNORE NULLS) OVER (PARTITION BY pool_address ORDER BY day
                                          ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS tk0Price
, tk1Address
, SUM(COALESCE(am1Delta::HUGEINT, 0)) OVER (PARTITION BY pool_address ORDER BY day) AS cumulativeAmount1
, LAST_VALUE(tk1Decimals IGNORE NULLS) OVER (PARTITION BY pool_address ORDER BY day
                                            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS tk1Decimals
, LAST_VALUE(tk1Price IGNORE NULLS) OVER (PARTITION BY pool_address ORDER BY day
                                          ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS tk1Price
FROM current_snapshot_data_merged_with_post_snapshot_data
)
SELECT * , coalesce(tvl0, 0) + coalesce(tvl1, 0) AS TVL
FROM (
SELECT 
* 
, (cumulativeAmount0/POW(10, tk0Decimals)) * tk0Price AS tvl0
, (cumulativeAmount1/POW(10, tk1Decimals)) * tk1Price AS tvl1
FROM full_info
)
""").to_table("tvlInfo_per_pool")

new_snapshot = duckdb.sql(f"""
COPY (
SELECT
pool_address
, day::DATE::VARCHAR AS snapshot_date
, cumulativeAmount0::VARCHAR AS cumulativeAmount0
, cumulativeAmount1::VARCHAR AS cumulativeAmount1
, tk0Address, tk0Decimals, tk0Price
, tk1Address, tk1Decimals, tk1Price
FROM tvlInfo_per_pool
WHERE day = (SELECT MAX(day) - INTERVAL '1' DAY FROM tvlInfo_per_pool)
ORDER BY pool_address
) TO '/Users/oguzkarabulut/Desktop/decentralizedanalysis.com/the_site/robinhood_uniswap_dashboard/30September/tvl_snapshot_2026-09-27.json' (FORMAT json, ARRAY true)
""")

website_data = duckdb.sql(f"""
WITH
tvl_top50 AS (
SELECT
t.day
, COALESCE(top.poolAddress, 'others') AS poolAddress
, COALESCE(top.poolName, 'others') AS poolName
, SUM(FLOOR(t.TVL))::BIGINT AS tvl
FROM tvlInfo_per_pool t
LEFT JOIN top50_poolAddress_poolName top ON t.pool_address = top.poolAddress
WHERE t.day > TIMESTAMP '{current_tvl_snapshot_date}'
GROUP BY 1, 2, 3
)
, new_days AS (
SELECT
tt.day, tt.poolAddress, tt.poolName, tt.tvl
, dv.dailyVol, dv.dailyFee
, dv.nSwaps_0_10, dv.nSwaps_10_100, dv.nSwaps_100_1k, dv.nSwaps_1k_10k
, dv.nSwaps_10k_100k, dv.nSwaps_100k_1m, dv.nSwaps_1m_
FROM tvl_top50 tt
LEFT JOIN daily_vol_top50 dv ON dv.day = tt.day AND dv.poolAddress = tt.poolAddress
)
, old_days AS (
SELECT
day::TIMESTAMP AS day, poolAddress, poolName, tvl
, dailyVol, dailyFee
, nSwaps_0_10, nSwaps_10_100, nSwaps_100_1k, nSwaps_1k_10k
, nSwaps_10k_100k, nSwaps_100k_1m, nSwaps_1m_
FROM current_daily_tvl_vol_data
WHERE day::TIMESTAMP <= TIMESTAMP '{current_tvl_snapshot_date}'
)
SELECT * FROM old_days
UNION ALL
SELECT * FROM new_days
ORDER BY day, dailyVol DESC NULLS LAST
""").df()

website_data.to_json(
    "/Users/oguzkarabulut/Desktop/decentralizedanalysis.com/the_site/robinhood_uniswap_dashboard/30September/v3_daily_tvl_vol_2026-09-28.json"
    , orient="records", date_format="iso", date_unit="s", indent=2
)
