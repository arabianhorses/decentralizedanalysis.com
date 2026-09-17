/*
first we are going to create table and fill it with eth and weth prices 
it may looks ambigous, but having healthy price feed for ETH + USDG = 1 will provide easiness for the rest of the tokens

*/
CREATE TABLE IF NOT EXISTS `decentralizedanalysis.robinhood.robinhood_token_prices` (
    hour          TIMESTAMP NOT NULL,
    tokenAddress  STRING    NOT NULL,
    tokenSymbol   STRING,
    tokenDecimals INT64,
    price         FLOAT64
  )
  PARTITION BY DATE(hour)
  CLUSTER BY tokenAddress;

  INSERT INTO `decentralizedanalysis.robinhood.robinhood_token_prices`
    (hour, tokenAddress, tokenSymbol, tokenDecimals, price)
WITH
usdg_v3_pools AS (
  SELECT
    CONCAT(tm0.symbol, '/', tm1.symbol, ' - ', CAST(pc.fee AS FLOAT64)/POW(10,6), '%', ' | ', pc.tickSpacing) AS poolName
  , pc.pool_address
  , pc.token0 AS tk0Address, tm0.symbol AS tk0Symbol, tm0.decimals AS tk0Decimals
  , pc.token1 AS tk1Address, tm1.symbol AS tk1Symbol, tm1.decimals AS tk1Decimals
  , pc.block_hour AS poolCreationHour
  , pc.generatedIndex AS poolCreationGi
  FROM `decentralizedanalysis.robinhood.robinhood_uniswapv3_pools` pc
  INNER JOIN `decentralizedanalysis.robinhood.token_mapping` tm0 ON pc.token0 = tm0.token_address
  INNER JOIN `decentralizedanalysis.robinhood.token_mapping` tm1 ON pc.token1 = tm1.token_address
  WHERE (pc.token0 = '0x5fc5360d0400a0fd4f2af552add042d716f1d168' OR pc.token1 = '0x5fc5360d0400a0fd4f2af552add042d716f1d168')
),
usdg_v4_pools AS (
  SELECT
    -- fee 0x800000 (8388608) is the dynamic-fee flag, not a rate: dividing it
    -- by 1e6 would print a nonsense "8.388608%".
    CONCAT(tm0.symbol, '/', tm1.symbol, ' - ',
           CASE WHEN pi.fee = 8388608 THEN 'dynamic'
                ELSE CONCAT(CAST(CAST(pi.fee AS FLOAT64)/POW(10,6) AS STRING), '%') END,
           ' | ', CAST(CAST(pi.tickSpacing AS INT64) AS STRING),
           CASE WHEN pi.hookAddress != '0x0000000000000000000000000000000000000000'
                THEN CONCAT(' | hook ', pi.hookAddress) ELSE '' END) AS poolName
  , pi.poolId AS pool_address          -- normalised: v4 pool identity is a bytes32 id
  , pi.currency0 AS tk0Address, tm0.symbol AS tk0Symbol, tm0.decimals AS tk0Decimals
  , pi.currency1 AS tk1Address, tm1.symbol AS tk1Symbol, tm1.decimals AS tk1Decimals
  , pi.block_hour AS poolCreationHour
  , pi.generatedIndex AS poolCreationGi
  FROM `decentralizedanalysis.robinhood.robinhood_uniswapv4_pool_initializations` pi
  INNER JOIN `decentralizedanalysis.robinhood.token_mapping` tm0 ON pi.currency0 = tm0.token_address
  INNER JOIN `decentralizedanalysis.robinhood.token_mapping` tm1 ON pi.currency1 = tm1.token_address
  WHERE (pi.currency0 = '0x5fc5360d0400a0fd4f2af552add042d716f1d168' OR pi.currency1 = '0x5fc5360d0400a0fd4f2af552add042d716f1d168')
)
, prices_from_swaps AS (
SELECT
  'v3' AS protocol
, usdp.poolName
, swa.block_hour AS swapHour
, CASE
    WHEN usdp.tk0Address = '0x5fc5360d0400a0fd4f2af552add042d716f1d168' THEN usdp.tk1Address
    WHEN usdp.tk1Address = '0x5fc5360d0400a0fd4f2af552add042d716f1d168' THEN usdp.tk0Address
    ELSE 'error'
  END AS tokenAddressToPrice
, CASE
    WHEN usdp.tk0Address = '0x5fc5360d0400a0fd4f2af552add042d716f1d168' THEN usdp.tk1Symbol
    WHEN usdp.tk1Address = '0x5fc5360d0400a0fd4f2af552add042d716f1d168' THEN usdp.tk0Symbol
    ELSE 'error'
  END AS tokenSymbolToPrice
, CASE
    WHEN usdp.tk0Address = '0x5fc5360d0400a0fd4f2af552add042d716f1d168' THEN usdp.tk1Decimals
    WHEN usdp.tk1Address = '0x5fc5360d0400a0fd4f2af552add042d716f1d168' THEN usdp.tk0Decimals
    ELSE 31
  END AS tokenDecimalsToPrice
, CASE
    WHEN usdp.tk0Address = '0x5fc5360d0400a0fd4f2af552add042d716f1d168' THEN ABS((swa.amount0/POW(10,usdp.tk0Decimals))/(swa.amount1/POW(10,usdp.tk1Decimals)))
    WHEN usdp.tk1Address = '0x5fc5360d0400a0fd4f2af552add042d716f1d168' THEN ABS((swa.amount1/POW(10,usdp.tk1Decimals))/(swa.amount0/POW(10,usdp.tk0Decimals)))
    ELSE 31313131313131
  END AS tokenPrice
, CASE
    WHEN usdp.tk0Address = '0x5fc5360d0400a0fd4f2af552add042d716f1d168' THEN ABS((swa.amount0/POW(10,usdp.tk0Decimals)))
    WHEN usdp.tk1Address = '0x5fc5360d0400a0fd4f2af552add042d716f1d168' THEN ABS((swa.amount1/POW(10,usdp.tk1Decimals)))
  END AS usdAmount
FROM `decentralizedanalysis.robinhood.robinhood_uniswapv3_swaps` swa
INNER JOIN usdg_v3_pools usdp ON swa.pool_address = usdp.pool_address
WHERE swa.block_date < '2026-09-18'
AND swa.amount0 != 0

UNION ALL

SELECT
  'v4' AS protocol
, usdp.poolName
, swa.block_hour AS swapHour
, CASE
    WHEN usdp.tk0Address = '0x5fc5360d0400a0fd4f2af552add042d716f1d168' THEN usdp.tk1Address
    WHEN usdp.tk1Address = '0x5fc5360d0400a0fd4f2af552add042d716f1d168' THEN usdp.tk0Address
    ELSE 'error'
  END AS tokenAddressToPrice
, CASE
    WHEN usdp.tk0Address = '0x5fc5360d0400a0fd4f2af552add042d716f1d168' THEN usdp.tk1Symbol
    WHEN usdp.tk1Address = '0x5fc5360d0400a0fd4f2af552add042d716f1d168' THEN usdp.tk0Symbol
    ELSE 'error'
  END AS tokenSymbolToPrice
, CASE
    WHEN usdp.tk0Address = '0x5fc5360d0400a0fd4f2af552add042d716f1d168' THEN usdp.tk1Decimals
    WHEN usdp.tk1Address = '0x5fc5360d0400a0fd4f2af552add042d716f1d168' THEN usdp.tk0Decimals
    ELSE 31
  END AS tokenDecimalsToPrice
, CASE
    WHEN usdp.tk0Address = '0x5fc5360d0400a0fd4f2af552add042d716f1d168' THEN ABS((swa.amount0/POW(10,usdp.tk0Decimals))/(swa.amount1/POW(10,usdp.tk1Decimals)))
    WHEN usdp.tk1Address = '0x5fc5360d0400a0fd4f2af552add042d716f1d168' THEN ABS((swa.amount1/POW(10,usdp.tk1Decimals))/(swa.amount0/POW(10,usdp.tk0Decimals)))
    ELSE 31313131313131
  END AS tokenPrice
, CASE
    WHEN usdp.tk0Address = '0x5fc5360d0400a0fd4f2af552add042d716f1d168' THEN ABS((swa.amount0/POW(10,usdp.tk0Decimals)))
    WHEN usdp.tk1Address = '0x5fc5360d0400a0fd4f2af552add042d716f1d168' THEN ABS((swa.amount1/POW(10,usdp.tk1Decimals)))
  END AS usdAmount
FROM `decentralizedanalysis.robinhood.robinhood_uniswapv4_swaps` swa
INNER JOIN usdg_v4_pools usdp ON swa.poolId = usdp.pool_address
WHERE swa.block_date < '2026-09-18'
AND swa.amount0 != 0
)
, prices_edited AS (
SELECT 
swapHour AS hour
, tokenAddressToPrice AS tokenAddress
, tokenSymbolToPrice AS tokenSymbol
, tokenDecimalsToPrice AS tokenDecimals
, tokenPrice AS price
, usdAmount AS volumeUsd
 FROM prices_from_swaps
WHERE usdAmount > 10
)
SELECT * FROM (
SELECT 
hour, tokenAddress, tokenSymbol, tokenDecimals 
, APPROX_QUANTILES(price, 2)[OFFSET(1)] AS price
FROM prices_edited
GROUP BY 1, 2, 3, 4
)
WHERE tokenAddress IN ('0x0000000000000000000000000000000000000000', '0x0bd7d308f8e1639fab988df18a8011f41eacad73')
