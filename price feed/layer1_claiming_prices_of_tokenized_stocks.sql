/*
layer1 -- prices every other token in token_mapping against the anchors.

Depends on layer0 + layer0_1 having run: this reads ETH/WETH/USDG prices back
out of robinhood_token_prices and multiplies through them. Anchors are gapless
from 2026-06-29, which is why the window starts there.

  anchor pair -> token price in anchor units -> x anchor's USDG price -> USDG price

Window: 2026-06-29 .. 2026-09-15 (where every decoded table ends).

## Exactly one anchor side

`(token0 IN anchors) != (token1 IN anchors)` is XOR. It keeps pools with one
anchor side and drops BOTH anchor/anchor pools (ETH/WETH, USDG/ETH, USDG/WETH,
which are layer 0's job) and non-anchor/non-anchor pools (which we cannot price).

## The $10 floor is applied AFTER conversion

volumeUsd is dollars. On an ETH-paired pool the raw anchor amount is in ETH, so
filtering before the multiply would have meant a ~$17,000 floor.

## KNOWN DEFECT: ~1.25% of rows are wrong, some by 10^6

yes some prices came malicous well actually these are on-chain realized values however generalizing them for all hour
is not safe we will return that bad pricing things later

## Re-running duplicates

I made claude write this script and forgot when not matched thing so 

INSERT, not MERGE, and BigQuery has no unique constraint, so a second run over
the same window doubles every row. Delete the window first. Anchors cannot
collide: the XOR filter means the priced token is never ETH, WETH or USDG.


*/
INSERT INTO `decentralizedanalysis.robinhood.robinhood_token_prices`
  (hour, tokenAddress, tokenSymbol, tokenDecimals, price)
WITH
anchor_set AS (
  SELECT a FROM UNNEST([
    '0x0000000000000000000000000000000000000000',   -- ETH  (native), 18
    '0x0bd7d308f8e1639fab988df18a8011f41eacad73',   -- WETH,          18
    '0x5fc5360d0400a0fd4f2af552add042d716f1d168'    -- USDG,           6
  ]) AS a
),
tokens AS (
  SELECT token_address, symbol, decimals
  FROM `decentralizedanalysis.robinhood.token_mapping`
),
v3_pools AS (
  SELECT
    pc.pool_address AS poolKey
  , pc.token0 IN (SELECT a FROM anchor_set)                                              AS anchorIsToken0
  , IF(pc.token0 IN (SELECT a FROM anchor_set), pc.token0,     pc.token1)     AS anchorAddress
  , IF(pc.token0 IN (SELECT a FROM anchor_set), tm0.decimals, tm1.decimals)   AS anchorDecimals
  , IF(pc.token0 IN (SELECT a FROM anchor_set), pc.token1,    pc.token0)      AS tokenAddress
  , IF(pc.token0 IN (SELECT a FROM anchor_set), tm1.symbol,   tm0.symbol)     AS tokenSymbol
  , IF(pc.token0 IN (SELECT a FROM anchor_set), tm1.decimals, tm0.decimals)   AS tokenDecimals
  FROM `decentralizedanalysis.robinhood.robinhood_uniswapv3_pools` pc
  JOIN tokens tm0 ON pc.token0 = tm0.token_address
  JOIN tokens tm1 ON pc.token1 = tm1.token_address
  WHERE (pc.token0 IN (SELECT a FROM anchor_set)) != (pc.token1 IN (SELECT a FROM anchor_set))
),
v4_pools AS (
  SELECT
    pi.poolId AS poolKey
  , pi.currency0 IN (SELECT a FROM anchor_set)                                           AS anchorIsToken0
  , IF(pi.currency0 IN (SELECT a FROM anchor_set), pi.currency0, pi.currency1) AS anchorAddress
  , IF(pi.currency0 IN (SELECT a FROM anchor_set), tm0.decimals, tm1.decimals) AS anchorDecimals
  , IF(pi.currency0 IN (SELECT a FROM anchor_set), pi.currency1, pi.currency0) AS tokenAddress
  , IF(pi.currency0 IN (SELECT a FROM anchor_set), tm1.symbol,   tm0.symbol)   AS tokenSymbol
  , IF(pi.currency0 IN (SELECT a FROM anchor_set), tm1.decimals, tm0.decimals) AS tokenDecimals
  FROM `decentralizedanalysis.robinhood.robinhood_uniswapv4_pool_initializations` pi
  JOIN tokens tm0 ON pi.currency0 = tm0.token_address
  JOIN tokens tm1 ON pi.currency1 = tm1.token_address
  WHERE (pi.currency0 IN (SELECT a FROM anchor_set)) != (pi.currency1 IN (SELECT a FROM anchor_set))
),
legs AS (
  SELECT swa.block_hour AS hour, p.tokenAddress, p.tokenSymbol, p.tokenDecimals, p.anchorAddress
  , ABS(IF(p.anchorIsToken0, swa.amount0, swa.amount1)) / POW(10, p.anchorDecimals) AS anchorAmount
  , ABS(IF(p.anchorIsToken0, swa.amount1, swa.amount0)) / POW(10, p.tokenDecimals)  AS tokenAmount
  FROM `decentralizedanalysis.robinhood.robinhood_uniswapv3_swaps` swa
  JOIN v3_pools p ON swa.pool_address = p.poolKey
  WHERE swa.block_date BETWEEN '2026-06-29' AND '2026-09-15'
    AND swa.amount0 != 0 AND swa.amount1 != 0
  UNION ALL
  SELECT swa.block_hour, p.tokenAddress, p.tokenSymbol, p.tokenDecimals, p.anchorAddress
  , ABS(IF(p.anchorIsToken0, swa.amount0, swa.amount1)) / POW(10, p.anchorDecimals)
  , ABS(IF(p.anchorIsToken0, swa.amount1, swa.amount0)) / POW(10, p.tokenDecimals)
  FROM `decentralizedanalysis.robinhood.robinhood_uniswapv4_swaps` swa
  JOIN v4_pools p ON swa.poolId = p.poolKey
  WHERE swa.block_date BETWEEN '2026-06-29' AND '2026-09-15'
    AND swa.amount0 != 0 AND swa.amount1 != 0
),
priced AS (
  SELECT l.hour, l.tokenAddress, l.tokenSymbol, l.tokenDecimals
  , (l.anchorAmount / l.tokenAmount) * ap.price AS price
  , l.anchorAmount * ap.price                   AS volumeUsd
  FROM legs l
  JOIN `decentralizedanalysis.robinhood.robinhood_token_prices` ap
    ON ap.hour = l.hour AND ap.tokenAddress = l.anchorAddress
),
blended AS (
  SELECT hour, tokenAddress, ANY_VALUE(tokenSymbol) AS tokenSymbol
  , ANY_VALUE(tokenDecimals) AS tokenDecimals
  , APPROX_QUANTILES(price, 2)[OFFSET(1)] AS price
  , SUM(volumeUsd) AS volumeUsd
  , COUNT(*)       AS swaps
  FROM priced
  WHERE volumeUsd > 10
  GROUP BY hour, tokenAddress
)
SELECT hour, tokenAddress, tokenSymbol, tokenDecimals, price
FROM blended
