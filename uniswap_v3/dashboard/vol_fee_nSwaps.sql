/*
I have written script myself then lost it, and reproduced this via claude, so this script written by claude 
it knows what we have in tables + output table it is a simple script so I assume it is correct 
vol_fee_nswaps_v3.sql -- Uniswap v3 on Robinhood Chain, one row per (block_date, pool).

Output = vol_fee_nSwaps_v3_full.parquet:
  block_date, pool_address, poolName, feeTier, dailyVol, fee,
  nSwaps_0_10 .. nSwaps_1m_, swaps, priced_swaps

Parameters (query parameters, not DECLARE, so a dry run prices the real scan):
  @start_date DATE   first day with prices on this chain: 2026-06-11
  @end_date   DATE   last complete day

Method
- Volume is the INPUT leg of each swap, valued at that hour's token price.
  v3 amounts are pool-perspective, so the input leg is the positive one.
  Uniswap takes the fee out of the input and the Swap event reports the gross
  input, so volume x feeTier is the fee actually collected.
- If the input token has no price that hour, the output leg is valued instead.
  A WETH/unknown pool is therefore still priced off its WETH side.
- A swap with neither leg priced counts in `swaps` but not `priced_swaps`,
  and adds nothing to volume or fees.
- Only pools created by the Uniswap v3 factory (robinhood_uniswapv3_pools);
  PancakeSwap v3 and other forks emit the same Swap event and are dropped here.
- poolName is 'SYM0/SYM1 | CL-<tickSpacing>' when both tokens are in
  token_mapping, NULL otherwise.
- Amounts are BIGNUMERIC. Each swap is converted to FLOAT64 on its own, after
  scaling by decimals; nothing raw is summed in float.
*/

WITH
swaps AS (
  SELECT
    s.block_date
  , s.block_hour
  , s.pool_address
  , s.amount0
  , s.amount1
  , p.token0
  , p.token1
  , p.fee / 1e6 AS feeTier
  FROM `decentralizedanalysis.robinhood.robinhood_uniswapv3_swaps` s
  JOIN `decentralizedanalysis.robinhood.robinhood_uniswapv3_pools` p
    ON p.pool_address = s.pool_address
  WHERE s.block_date BETWEEN @start_date AND @end_date
)

, hourly_prices AS (
  SELECT hour, tokenAddress, tokenDecimals, price
  FROM `decentralizedanalysis.robinhood.robinhood_token_prices`
  WHERE DATE(hour) BETWEEN @start_date AND @end_date
)

, swap_legs AS (
  SELECT
    s.block_date
  , s.pool_address
  , s.feeTier
  -- input leg first, output leg second
  , IF(s.amount0 > 0, s.amount0, s.amount1)          AS inAmount
  , IF(s.amount0 > 0, pr0.price, pr1.price)          AS inPrice
  , IF(s.amount0 > 0, pr0.tokenDecimals, pr1.tokenDecimals) AS inDecimals
  , IF(s.amount0 > 0, s.amount1, s.amount0)          AS outAmount
  , IF(s.amount0 > 0, pr1.price, pr0.price)          AS outPrice
  , IF(s.amount0 > 0, pr1.tokenDecimals, pr0.tokenDecimals) AS outDecimals
  FROM swaps s
  LEFT JOIN hourly_prices pr0 ON pr0.tokenAddress = s.token0 AND pr0.hour = s.block_hour
  LEFT JOIN hourly_prices pr1 ON pr1.tokenAddress = s.token1 AND pr1.hour = s.block_hour
)

, swap_values AS (
  SELECT
    block_date
  , pool_address
  , feeTier
  , CASE
      WHEN inPrice IS NOT NULL
        THEN CAST(ABS(inAmount) / POW(10, inDecimals) AS FLOAT64) * inPrice
      WHEN outPrice IS NOT NULL
        THEN CAST(ABS(outAmount) / POW(10, outDecimals) AS FLOAT64) * outPrice
    END AS volumeUsd
  FROM swap_legs
)

, pool_names AS (
  SELECT
    p.pool_address
  , CONCAT(t0.symbol, '/', t1.symbol, ' | CL-', CAST(p.tickSpacing AS STRING)) AS poolName
  FROM `decentralizedanalysis.robinhood.robinhood_uniswapv3_pools` p
  JOIN `decentralizedanalysis.robinhood.token_mapping` t0 ON t0.token_address = p.token0
  JOIN `decentralizedanalysis.robinhood.token_mapping` t1 ON t1.token_address = p.token1
)

SELECT
  v.block_date
, v.pool_address
, n.poolName
, ANY_VALUE(v.feeTier)                      AS feeTier
, ROUND(SUM(v.volumeUsd), 1)                AS dailyVol
, ROUND(SUM(v.volumeUsd * v.feeTier), 2)    AS fee
, COUNTIF(v.volumeUsd > 0      AND v.volumeUsd <= 10)      AS nSwaps_0_10
, COUNTIF(v.volumeUsd > 10     AND v.volumeUsd <= 100)     AS nSwaps_10_100
, COUNTIF(v.volumeUsd > 100    AND v.volumeUsd <= 1000)    AS nSwaps_100_1k
, COUNTIF(v.volumeUsd > 1000   AND v.volumeUsd <= 10000)   AS nSwaps_1k_10k
, COUNTIF(v.volumeUsd > 10000  AND v.volumeUsd <= 100000)  AS nSwaps_10k_100k
, COUNTIF(v.volumeUsd > 100000 AND v.volumeUsd <= 1000000) AS nSwaps_100k_1m
, COUNTIF(v.volumeUsd > 1000000)                           AS nSwaps_1m_
, COUNT(*)                                  AS swaps
, COUNTIF(v.volumeUsd IS NOT NULL)          AS priced_swaps
FROM swap_values v
LEFT JOIN pool_names n ON n.pool_address = v.pool_address
GROUP BY v.block_date, v.pool_address, n.poolName
