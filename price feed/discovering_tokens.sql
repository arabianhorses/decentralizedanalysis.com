/*
purpose of this query discovering tokens with high volume so we can know what to add onto token_mapping table 
you will see filters like these on uniswapv4 query 
AND swa.liquidity > 1000
AND pi.hookAddress = '0x0000000000000000000000000000000000000000' AND pi.fee > 0 
reason of them 
filtering out such transactions 
https://robin.etherscan.io/tx/0xd4077f3a90015b5c8fe4e1e7195fcb5b25c1ec97c4997d7a21bc726a3d8a7d4d#eventlog

otherwise some swaps looks like 500M USDG swapped which is actually not 
since we need speed I did not look them into deeper why they areexist how they are faking the volume and so on 
just figured out appliying a filter on hooks and feeTier will work and it worked I guess
*/
WITH
swaps_with_prices AS (
SELECT
  'v3' AS protocol
, swa.block_hour
, swa.pool_address
, pc.token0 AS tk0Address, pr0.tokenSymbol AS tk0Symbol, swa.amount0, pr0.tokenDecimals AS tk0Decimals, pr0.price AS tk0Price
, pc.token1 AS tk1Address, pr1.tokenSymbol AS tk1Symbol, swa.amount1, pr1.tokenDecimals AS tk1Decimals, pr1.price AS tk1Price
, swa.generatedIndex
, swa.transaction_hash

FROM `decentralizedanalysis.robinhood.robinhood_uniswapv3_swaps` swa
LEFT JOIN `decentralizedanalysis.robinhood.robinhood_uniswapv3_pools` pc ON swa.pool_address = pc.pool_address
LEFT JOIN `decentralizedanalysis.robinhood.robinhood_token_prices` pr0 ON pc.token0 = pr0.tokenAddress AND swa.block_hour = pr0.hour
LEFT JOIN `decentralizedanalysis.robinhood.robinhood_token_prices` pr1 ON pc.token1 = pr1.tokenAddress AND swa.block_hour = pr1.hour
WHERE swa.block_date > '2026-08-18' --AND swa.block_date < '2026-08-20'

UNION ALL

SELECT
  'v4' AS protocol
, swa.block_hour
, swa.poolId AS pool_address
, pi.currency0 AS tk0Address, pr0.tokenSymbol AS tk0Symbol, -1 * swa.amount0, pr0.tokenDecimals AS tk0Decimals, pr0.price AS tk0Price
, pi.currency1 AS tk1Address, pr1.tokenSymbol AS tk1Symbol, -1 * swa.amount1, pr1.tokenDecimals AS tk1Decimals, pr1.price AS tk1Price
, swa.generatedIndex
, swa.transaction_hash
FROM `decentralizedanalysis.robinhood.robinhood_uniswapv4_swaps` swa
LEFT JOIN `decentralizedanalysis.robinhood.robinhood_uniswapv4_pool_initializations` pi ON swa.poolId = pi.poolId
LEFT JOIN `decentralizedanalysis.robinhood.robinhood_token_prices` pr0 ON pi.currency0 = pr0.tokenAddress AND swa.block_hour = pr0.hour
LEFT JOIN `decentralizedanalysis.robinhood.robinhood_token_prices` pr1 ON pi.currency1 = pr1.tokenAddress AND swa.block_hour = pr1.hour
WHERE swa.block_date > '2026-08-18' --AND swa.block_date < '2026-08-23'
AND swa.liquidity > 1000
AND pi.hookAddress = '0x0000000000000000000000000000000000000000' AND pi.fee > 0 
)
, swaps_with_vol AS (
SELECT
CASE
  WHEN tk0Decimals IS NOT NULL AND tk1Decimals IS NULL THEN ABS(amount0)/POW(10,tk0Decimals) * tk0Price
  WHEN tk0Decimals IS NULL AND tk1Decimals IS NOT NULL THEN ABS(amount1)/POW(10,tk1Decimals) * tk1Price
  WHEN tk0Decimals IS NOT NULL AND tk1Decimals IS NOT NULL AND amount0 > 0 THEN amount0/POW(10,tk0Decimals) * tk0Price
  WHEN tk0Decimals IS NOT NULL AND tk1Decimals IS NOT NULL AND amount1 > 0 THEN amount1/POW(10,tk1Decimals) * tk1Price
END AS vol
, CASE
  WHEN tk0Symbol IS NULL THEN tk0Address ELSE tk1Address
  END AS tokenToDiscoveryAddress
, *
FROM swaps_with_prices
WHERE (tk0Symbol IS NULL OR tk1Symbol IS NULL)
)
--SELECT * FROM swaps_with_vol

SELECT * FROM (
SELECT
  tokenToDiscoveryAddress
, SUM(vol) AS vol
, MAX(vol) AS maxVol
, MAX_BY(transaction_hash, vol ) AS maxVolTxnHash
, COUNT(*) AS cnt
FROM swaps_with_vol
GROUP BY 1
)
ORDER BY vol DESC
LIMIT 1000
