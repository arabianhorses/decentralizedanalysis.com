#as you can imagine fully wirten by human aka me if you feel confused hit my dm arabianhorses0 on telegram 
import pandas as pd 
import duckdb 

duckdb.sql("SET TimeZone='UTC'")

daily_deltas = pd.read_parquet ("/Users/oguzkarabulut/Desktop/decentralizedanalysis.com/the_site/robinhood_uniswap_dashboard/22September/swaps_mints_collects_flash_daily_deltas.parquet")


cumulative_amounts = duckdb.sql(f"""
WITH
cumulative_amounts AS (
SELECT * FROM 
(
SELECT 
pool_address, block_date
, SUM(CAST(am0Delta AS HUGEINT)) OVER(PARTITION BY pool_address ORDER BY block_date) AS cumulativeAmount0
, SUM(CAST(am1Delta AS HUGEINT)) OVER(PARTITION BY pool_address ORDER BY block_date) AS cumulativeAmount1
FROM daily_deltas
WHERE pool_address NOT IN 
    (
  '0x15715eaaad648be2a983847b6cc998b1546a0585'
  , '0x0e14ed480e1b12391bd46c988c8154442d5cdf25'
  , '0x4378a08a044efe62eb7eed0382349a0ac93ff457'
  , '0x99d1964702cbb853e70f22cf146bab36b383782c'
  , '0x174311af8c5704a2e54c15f45ac3e445d4737e82'
  , '0x5ac3d6b1ca3c638e7aac4255f444acd569ffda00'
  , '0xaefbc8fb41d9efb9f0f8f1bab48a8659e2f37c45'
  , '0x666cf31e99c2b33a23fefc6e5771cc50069a2784'
  , '0x27d9eab51885e4591fe7ee9fea84308457a5eb4c'
  , '0x5ec825c00c4b1b799589ba2b37aeaa532fbff843'
  , '0x365e273b73bd27e8de4e86d3fbde056ff808524b'
  , '0x40a46de03ab465cf46e51fc60df993ccb782044f'
  , '0x70098f3b4bea4e88170ae07619586f017f1636f7'
  , '0xeb459fefeae02cf0b2938164a193532625558743'
  , '0x85c1d3f88d8c0322cb75964f333d7e8e5a029006'
  , '0xaf98668207f86ef72dfcdb4426f815d5ecbc4947'
  , '0x46204440f30858d890630fddff7d82a32970a51b'
  , '0xf1608ed66ac8972e0398e0fc1b60625736d802f1'
  , '0x4a1e306254172f1ba551d5180be5cd2ee9d50c07'
  , '0x5fb5d433b00ce13c18a0c650c61b212e2f42b9c3'
  , '0x555ffa32d1eda8ff99ec0fc17b4236015e76a162'
  , '0xa22b86cf7538f94943fa9ab21ada6a6fa40ce5f9'
  , '0x8752c26b9e279fef726dd875574e5f70b0d8088b'
  , '0x28e839bed642ac1ac2c3d17d9c5426ff72f6cf65'
  , '0x48495fab9d3b2a09f2da707741d685db91e252a5'
  , '0xaedbc1bb644ef98de5ece416b3e5dd6586ffef13'

  , '0x158b81e70ac94e804d74bb88a85e96fa5c4d5049'
  , '0x365e273b73bd27e8de4e86d3fbde056ff808524b'
  , '0x40a46de03ab465cf46e51fc60df993ccb782044f'
  , '0x48023df21197af7b969e38acf85121295753149f'
  , '0x4a1e306254172f1ba551d5180be5cd2ee9d50c07'
  , '0x7bb66adf3cf3bbc49167f8e5953ceff277bb24bf'
  , '0x85c1d3f88d8c0322cb75964f333d7e8e5a029006'
  , '0xaf98668207f86ef72dfcdb4426f815d5ecbc4947'
  , '0xf6a95ef2d3c4ef23fd1cefe4b6f1e3de30b74d8d'
  , '0xfe070c6f27f547e68b2cfee4ae8f4c44aa5d2f9b'

    )
)
)
, date_boundaries_X_pool_addresses AS (
SELECT pool_address, firstAppearance
, CASE WHEN lastAppearance < '2026-08-22' THEN lastAppearance ELSE lastDataDate END AS endBoundary
FROM (
SELECT 
pool_address
, MIN(block_date) AS firstAppearance
, MAX(block_date) AS lastAppearance
, MAX(MAX(block_date)) OVER(PARTITION BY 1) AS lastDataDate
FROM cumulative_amounts
GROUP BY 1
)
)

, pool_day_grid AS (                      
    SELECT pool_address
         , UNNEST(generate_series(firstAppearance, endBoundary, INTERVAL 1 DAY))::DATE AS day
    FROM date_boundaries_X_pool_addresses
)
SELECT * FROM (
SELECT 
pgd.pool_address , pgd.day
, COALESCE(cuma.cumulativeAmount0 , LAG(cuma.cumulativeAmount0 IGNORE NULLS)  OVER(PARTITION BY pgd.pool_address ORDER BY pgd.day) ) AS cumulativeAmount0
, COALESCE(cuma.cumulativeAmount1 , LAG(cuma.cumulativeAmount1 IGNORE NULLS)  OVER(PARTITION BY pgd.pool_address ORDER BY pgd.day) ) AS cumulativeAmount1
FROM pool_day_grid pgd
LEFT JOIN cumulative_amounts cuma ON pgd.pool_address = cuma.pool_address AND pgd.day = cuma.block_date 
)

            """) #.df() do we need df in here ? 




token_prices = pd.read_parquet("/Users/oguzkarabulut/Desktop/decentralizedanalysis.com/the_site/robinhood_uniswap_dashboard/data/token_prices.parquet")

daily_token_prices = duckdb.sql(f"""

SELECT day, tokenAddress, tokenDecimals, price FROM (
SELECT 
DATE_TRUNC('day', hour)::DATE AS day
, tokenAddress, tokenDecimals, price
, row_number() over(partition by tokenAddress, DATE_TRUNC('day', hour) ORDER BY hour DESC) AS rn
FROM token_prices
              )
WHERE rn = 1

""")#.df()
pool_creations = pd.read_parquet("/Users/oguzkarabulut/Desktop/decentralizedanalysis.com/the_site/robinhood_uniswap_dashboard/data/uniswapv3_pools.parquet")
token_mapping = pd.read_parquet("/Users/oguzkarabulut/Desktop/decentralizedanalysis.com/the_site/robinhood_uniswap_dashboard/data/token_mapping.parquet")

duckdb.sql(f"""
COPY (
WITH
snapshot_date AS (
SELECT max(day) - 1 AS snapshot_date FROM cumulative_amounts
                 )
, latest_prices AS (
SELECT tokenAddress, tokenDecimals, price FROM (
SELECT
tokenAddress, tokenDecimals, price
, ROW_NUMBER() OVER(PARTITION BY tokenAddress ORDER BY day DESC) AS rn
FROM daily_token_prices
WHERE day <= (SELECT snapshot_date FROM snapshot_date)
)
WHERE rn = 1
           )
SELECT
pool_address, day AS snapshot_date
, CAST(cumulativeAmount0 AS VARCHAR) AS cumulativeAmount0
, CAST(cumulativeAmount1 AS VARCHAR) AS cumulativeAmount1
, tk0Address, tk0Decimals, tk0Price
, tk1Address, tk1Decimals, tk1Price
FROM (
SELECT
cuma.pool_address, cuma.day, cuma.cumulativeAmount0, cuma.cumulativeAmount1
, pc.token0 AS tk0Address, lp0.tokenDecimals AS tk0Decimals, lp0.price AS tk0Price
, pc.token1 AS tk1Address, lp1.tokenDecimals AS tk1Decimals, lp1.price AS tk1Price
, CASE WHEN lp0.tokenDecimals IS NULL AND lp1.tokenDecimals IS NULL THEN 0 ELSE 1 END AS isEligible
FROM cumulative_amounts cuma
LEFT JOIN pool_creations pc ON cuma.pool_address = pc.pool_address
LEFT JOIN latest_prices lp0 ON pc.token0 = lp0.tokenAddress
LEFT JOIN latest_prices lp1 ON pc.token1 = lp1.tokenAddress
WHERE cuma.day = (SELECT snapshot_date FROM snapshot_date)
)
WHERE isEligible = 1
) TO
'/Users/oguzkarabulut/Desktop/decentralizedanalysis.com/the_site/robinhood_uniswap_dashboard/data/tvl_snapshot.json'
  (FORMAT json, ARRAY true)
""")

pool_names = duckdb.sql(f"""
SELECT 
pool_address, poolName
, tk0Address, tk1Address
FROM (
SELECT 
CONCAT(COALESCE(tm0.symbol, pc.token0), '/', COALESCE(tm1.symbol, pc.token1), ' CL-', pc.tickSpacing) AS poolName
, CASE WHEN tm0.symbol IS NULL AND tm1.symbol IS NULL THEN 0 ELSE 1 END AS isEligible
, pc.pool_address
, pc.token0 AS tk0Address, pc.token1 AS tk1Address
FROM pool_creations pc 
LEFT JOIN token_mapping tm0 ON pc.token0 = tm0.token_address
LEFT JOIN token_mapping tm1 ON pc.token1 = tm1.token_address
)
WHERE isEligible = 1
""")#.df()

tvl = duckdb.sql(f"""
WITH 
cumulativeAmounts_and_tokenInformations AS (

SELECT 
cuma.day , cuma.pool_address, pna.poolName
, cuma.cumulativeAmount0 , cuma.cumulativeAmount1  
, COALESCE(pr0.tokenDecimals , LAG(pr0.tokenDecimals IGNORE NULLS) OVER(PARTITION BY cuma.pool_address ORDER BY cuma.day) ) AS tk0D 
, COALESCE(pr0.price , LAG(pr0.price IGNORE NULLS) OVER(PARTITION BY cuma.pool_address ORDER BY cuma.day) ) AS tk0P 
, COALESCE(pr1.tokenDecimals , LAG(pr1.tokenDecimals IGNORE NULLS) OVER(PARTITION BY cuma.pool_address ORDER BY cuma.day) ) AS tk1D 
, COALESCE(pr1.price , LAG(pr1.price IGNORE NULLS) OVER(PARTITION BY cuma.pool_address ORDER BY cuma.day) ) AS tk1P 
FROM cumulative_amounts cuma 
INNER JOIN pool_names pna ON cuma.pool_address = pna.pool_address
LEFT JOIN daily_token_prices pr0 ON pna.tk0Address = pr0.tokenAddress AND cuma.day = pr0.day
LEFT JOIN daily_token_prices pr1 ON pna.tk1Address = pr1.tokenAddress AND cuma.day = pr1.day

)
SELECT 
day, pool_address, poolName 
, FLOOR( COALESCE(tvl0, 0) + COALESCE(tvl1, 0) ) AS tvl
FROM (
SELECT 
day, pool_address, poolName
, (cumulativeAmount0/POW(10, tk0D)) * tk0P AS tvl0
, (cumulativeAmount1/POW(10, tk1D)) * tk1P AS tvl1
FROM cumulativeAmounts_and_tokenInformations 
     )
""")#.df()

vol_fee_data = pd.read_json("/Users/oguzkarabulut/Desktop/decentralizedanalysis.com/the_site/robinhood_uniswap_dashboard/data/vol_fee_nSwaps_v3_2002.json")

top_50 = duckdb.sql(f"""
SELECT poolAddress, poolName FROM (
SELECT
*, ROW_NUMBER() OVER(PARTITION BY poolAddress ORDER BY day_) AS rn
FROM vol_fee_data
WHERE poolAddress != 'others'
)
WHERE rn = 1 
""")#.df()

tvl_aggregated = duckdb.sql(f"""
SELECT 
tvl.day, COALESCE(top.poolAddress, 'others') AS poolAddress, COALESCE(top.poolName, 'others') AS poolName
, SUM(tvl.tvl) AS tvl
FROM tvl tvl
LEFT JOIN top_50 top ON tvl.pool_address = top.poolAddress 
GROUP BY 1, 2, 3
""")#.df()

all_data_together = duckdb.sql(f"""
SELECT 
tva.day, tva.poolAddress , tva.poolName
, tva.tvl
, vfn.dailyVol, vfn.dailyFee 
, vfn.nSwaps_0_10, vfn.nSwaps_10_100, vfn.nSwaps_100_1k, vfn.nSwaps_1k_10k, vfn.nSwaps_10k_100k, vfn.nSwaps_100k_1m
, vfn.nSwaps_1m_
FROM tvl_aggregated tva
LEFT JOIN vol_fee_data vfn ON tva.day = vfn.day_ AND tva.poolAddress = vfn.poolAddress
ORDER BY tva.day, vfn.dailyVol DESC
""").df()

all_data_together.to_json(
    "/Users/oguzkarabulut/Desktop/decentralizedanalysis.com/the_site/robinhood_uniswap_dashboard/data/v3_daily_tvl_vol.json"
    , orient="records", date_format="iso", date_unit="s", indent=2
)


