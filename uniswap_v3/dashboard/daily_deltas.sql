/*
this is how we generate daily deltas file I know repo has been shitty, will I fix it ? dont think so but will make a 
proper one while preparing the dashboard for v4
*/

WITH bad_pools AS (
  SELECT * FROM UNNEST([
    '0x15715eaaad648be2a983847b6cc998b1546a0585','0x0e14ed480e1b12391bd46c988c8154442d5cdf25',
    '0x4378a08a044efe62eb7eed0382349a0ac93ff457','0x99d1964702cbb853e70f22cf146bab36b383782c',
    '0x174311af8c5704a2e54c15f45ac3e445d4737e82','0x5ac3d6b1ca3c638e7aac4255f444acd569ffda00',
    '0xaefbc8fb41d9efb9f0f8f1bab48a8659e2f37c45','0x666cf31e99c2b33a23fefc6e5771cc50069a2784',
    '0x27d9eab51885e4591fe7ee9fea84308457a5eb4c','0x5ec825c00c4b1b799589ba2b37aeaa532fbff843',
    '0x365e273b73bd27e8de4e86d3fbde056ff8085251fc60df993ccb782044f',
    '0x70098f3b4bea4e88170ae07619586f017f1636f7','0xeb459fefeae02cf0b2938164a193532625558743',
    '0x85c1d3f88d8c0322cb75964f333d7e8e5a0290cdb4426f815d5ecbc4947',
    '0x46204440f30858d890630fddff7d82a32970a51b','0xf1608ed66ac8972e0398e0fc1b60625736d802f1',
    '0x4a1e306254172f1ba551d5180be5cd2ee9d50c0c650c61b212e2f42b9c3',
    '0x555ffa32d1eda8ff99ec0fc17b4236015e76a162','0xa22b86cf7538f94943fa9ab21ada6a6fa40ce5f9',
    '0x8752c26b9e279fef726dd875574e5f70b0d8083d17d9c5426ff72f6cf65',
    '0x48495fab9d3b2a09f2da707741d685db91e252a5','0xaedbc1bb644ef98de5ece416b3e5dd6586ffef13'
  ]) AS pool_address
)


SELECT pool_address, block_date
, SUM(am0Delta) AS am0Delta, SUM(am1Delta) AS am1Delta
FROM (
  SELECT
  pool_address, block_date
  , SUM(amount0) AS am0Delta, sum(amount1) AS am1Delta
  FROM decentralizedanalysis.robinhood.robinhood_uniswapv3_swaps
  WHERE block_date > '2026-01-01'
  AND pool_address NOT IN (SELECT pool_address FROM bad_pools)
  GROUP BY 1, 2

  UNION ALL

  SELECT
  pool_address, block_date
  , SUM(amount0) AS am0Delta, sum(amount1) AS am1Delta
  FROM decentralizedanalysis.robinhood.robinhood_uniswapv3_liquidity_movements
  WHERE liquidityDelta > 0
  AND block_date > '2026-01-01'
  AND pool_address NOT IN (SELECT pool_address FROM bad_pools)
  GROUP BY 1, 2

  UNION ALL

  SELECT
  pool_address, block_date
  , -1 * SUM(amount0) AS am0Delta, -1 * SUM(amount1) AS am1Delta
  FROM decentralizedanalysis.robinhood.robinhood_uniswapv3_collects
  WHERE block_date > '2026-01-01'
  AND pool_address NOT IN (SELECT pool_address FROM bad_pools)
  GROUP BY 1, 2

  UNION ALL

  SELECT
  pool_address, block_date
  , SUM(paid0) AS am0Delta, sum(paid1) AS am1Delta
  FROM decentralizedanalysis.robinhood.robinhood_uniswapv3_flash
  WHERE block_date > '2026-01-01'
  AND pool_address NOT IN (SELECT pool_address FROM bad_pools)
  GROUP BY 1, 2
  )
GROUP BY 1, 2
