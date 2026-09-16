/*
in this script there are 3 queries for updating swaps, initialize and modifyliquidity tables, we are syncing raw logs 
table first, then running this query max_date and max_gidx(generatedIndex) is for efficiceny so we scan less data 
and for blocking duplications 

*/
DECLARE max_date DATE;
DECLARE max_gidx INT64;

SET max_date = (
  SELECT MAX(block_date)
  FROM `decentralizedanalysis.robinhood.robinhood_uniswapv4_swaps`
  WHERE block_date > CURRENT_DATE() - INTERVAL 2 DAY
);

IF max_date IS NULL THEN
  SET max_date = (
    SELECT MAX(block_date)
    FROM `decentralizedanalysis.robinhood.robinhood_uniswapv4_swaps`
    WHERE block_date > DATE_TRUNC(CURRENT_DATE() - INTERVAL 30 DAY, MONTH)
  );
END IF;

IF max_date IS NULL THEN
  SET max_date = DATE '2026-05-22';
END IF;

SET max_gidx = (
  SELECT MAX(generatedIndex)
  FROM `decentralizedanalysis.robinhood.robinhood_uniswapv4_swaps`
  WHERE block_date >= max_date
);

IF max_gidx IS NULL THEN
  SET max_gidx = -1;
END IF;

INSERT INTO `decentralizedanalysis.robinhood.robinhood_uniswapv4_swaps` (
  block_date, block_hour, transaction_hash, poolId, amount0, amount1, sqrtPriceX96,
  liquidity, tick, fee, sender, block_number, transaction_index, log_index,
  generatedIndex, address, topics, data
)
SELECT
  block_date
, block_hour
, transaction_hash
, topics[SAFE_OFFSET(1)]                               AS poolId
, udf.hex_to_int(SUBSTR(data, 3, 64))                  AS amount0
, udf.hex_to_int(SUBSTR(data, 67, 64))                 AS amount1
, udf.hex_to_uint_str(SUBSTR(data, 131, 64))           AS sqrtPriceX96
, udf.hex_to_uint(SUBSTR(data, 195, 64))               AS liquidity
, udf.hex_to_int(SUBSTR(data, 259, 64))                AS tick
, udf.hex_to_uint(SUBSTR(data, 323, 64))               AS fee
, CONCAT('0x', SUBSTR(topics[SAFE_OFFSET(2)], 27, 40)) AS sender
, block_number, transaction_index, log_index
, generatedIndex
, address
, topics, data
FROM `decentralizedanalysis.robinhood.robinhood_uniswapv4_raw_logs`
WHERE block_date >= max_date
  AND generatedIndex > max_gidx
  AND topic0 = '0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f' -- Swap (index_topic_1 bytes32 id, index_topic_2 address sender, int128 amount0, int128 amount1, uint160 sqrtPriceX96, uint128 liquidity, int24 tick, uint24 fee)
  ;




SET max_date = (
  SELECT MAX(block_date)
  FROM `decentralizedanalysis.robinhood.robinhood_uniswapv4_liquidity_modifications`
  WHERE block_date > CURRENT_DATE() - INTERVAL 2 DAY
);

IF max_date IS NULL THEN
  SET max_date = (
    SELECT MAX(block_date)
    FROM `decentralizedanalysis.robinhood.robinhood_uniswapv4_liquidity_modifications`
    WHERE block_date > DATE_TRUNC(CURRENT_DATE() - INTERVAL 30 DAY, MONTH)
  );
END IF;

IF max_date IS NULL THEN
  SET max_date = DATE '2026-05-22';
END IF;

SET max_gidx = (
  SELECT MAX(generatedIndex)
  FROM `decentralizedanalysis.robinhood.robinhood_uniswapv4_liquidity_modifications`
  WHERE block_date >= max_date
);

IF max_gidx IS NULL THEN
  SET max_gidx = -1;
END IF;

INSERT INTO `decentralizedanalysis.robinhood.robinhood_uniswapv4_liquidity_modifications` (
  block_date, block_hour, transaction_hash, poolId, tickLower, tickUpper,
  liquidityDelta, salt, sender, block_number, transaction_index, log_index,
  generatedIndex, address, topics, data
)
SELECT
  block_date
, block_hour
, transaction_hash
, topics[SAFE_OFFSET(1)]                               AS poolId
, udf.hex_to_int(SUBSTR(data, 3, 64))                  AS tickLower
, udf.hex_to_int(SUBSTR(data, 67, 64))                 AS tickUpper
, udf.hex_to_int(SUBSTR(data, 131, 64))                AS liquidityDelta
, CONCAT('0x', SUBSTR(data, 195, 64))                  AS salt
, CONCAT('0x', SUBSTR(topics[SAFE_OFFSET(2)], 27, 40)) AS sender
, block_number, transaction_index, log_index
, generatedIndex
, address
, topics, data
FROM `decentralizedanalysis.robinhood.robinhood_uniswapv4_raw_logs`
WHERE block_date >= max_date
  AND generatedIndex > max_gidx
  AND topic0 = '0xf208f4912782fd25c7f114ca3723a2d5dd6f3bcc3ac8db5af63baa85f711d5ec' -- ModifyLiquidity (index_topic_1 bytes32 id, index_topic_2 address sender, int24 tickLower, int24 tickUpper, int256 liquidityDelta, bytes32 salt);





SET max_date = (
  SELECT MAX(block_date)
  FROM `decentralizedanalysis.robinhood.robinhood_uniswapv4_pool_initializations`
  WHERE block_date > CURRENT_DATE() - INTERVAL 2 DAY
);

IF max_date IS NULL THEN
  SET max_date = (
    SELECT MAX(block_date)
    FROM `decentralizedanalysis.robinhood.robinhood_uniswapv4_pool_initializations`
    WHERE block_date > DATE_TRUNC(CURRENT_DATE() - INTERVAL 30 DAY, MONTH)
  );
END IF;

IF max_date IS NULL THEN
  SET max_date = DATE '2026-05-22';
END IF;

SET max_gidx = (
  SELECT MAX(generatedIndex)
  FROM `decentralizedanalysis.robinhood.robinhood_uniswapv4_pool_initializations`
  WHERE block_date >= max_date
);

IF max_gidx IS NULL THEN
  SET max_gidx = -1;
END IF;

INSERT INTO `decentralizedanalysis.robinhood.robinhood_uniswapv4_pool_initializations` (
  block_date, block_hour, transaction_hash, poolId, currency0, currency1, fee,
  tickSpacing, hookAddress, sqrtPriceX96, tick, block_number, transaction_index,
  log_index, generatedIndex, address, topics, data
)
SELECT
  block_date
, block_hour
, transaction_hash
, topics[SAFE_OFFSET(1)]                               AS poolId
, CONCAT('0x', SUBSTR(topics[SAFE_OFFSET(2)], 27, 40)) AS currency0
, CONCAT('0x', SUBSTR(topics[SAFE_OFFSET(3)], 27, 40)) AS currency1
, udf.hex_to_uint(SUBSTR(data, 3, 64))                 AS fee
, udf.hex_to_int(SUBSTR(data, 67, 64))                 AS tickSpacing
, CONCAT('0x', SUBSTR(data, 155, 40))                  AS hookAddress
, udf.hex_to_uint_str(SUBSTR(data, 195, 64))           AS sqrtPriceX96
, udf.hex_to_int(SUBSTR(data, 259, 64))                AS tick
, block_number, transaction_index, log_index
, generatedIndex
, address
, topics, data
FROM `decentralizedanalysis.robinhood.robinhood_uniswapv4_raw_logs`
WHERE block_date >= max_date
  AND generatedIndex > max_gidx
  AND topic0 = '0xdd466e674ea557f56295e2d0218a125ea4b4f0f6f3307b95f85e6110838d6438' -- Initialize (index_topic_1 bytes32 id, index_topic_2 address currency0, index_topic_3 address currency1, uint24 fee, int24 tickSpacing, address hooks, uint160 sqrtPriceX96, int24 tick)
;
