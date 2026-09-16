/*
In this script there are 4 queries, for updating the pools, swaps,
liquidity_movements and collects tables. We sync the raw logs table first, then
run this.

max_date prunes partitions, so we scan less data.
max_gidx (generatedIndex) is the forward cursor: it prunes further, and it is
the only thing preventing duplicate inserts -- do not remove it. max_date alone
does NOT stop duplicates.

The four blocks share max_date and max_gidx. That is safe: SET assigns
unconditionally, so a block whose first lookup finds nothing writes NULL instead
of inheriting the previous block's value, and its own IF chain then widens the
window for that table alone.


**pools runs first, and its watermark is shaped differently from the other
three.** It is the dimension table every pool_address in this schema refers to,
so it should never lag the facts that point at it. 


*/
DECLARE max_date DATE;
DECLARE max_gidx INT64;


/* ==== 1/4  pools ======================================================== */
/* Dimension table, unpartitioned: one tier, no CURRENT_DATE() window. */

SET max_date = (
  SELECT MAX(block_date)
  FROM `decentralizedanalysis.robinhood.robinhood_uniswapv3_pools`
);

/* Empty table: start at the factory's first PoolCreated, block 9,490. */
IF max_date IS NULL THEN
  SET max_date = DATE '2026-05-22';
END IF;

SET max_gidx = (
  SELECT MAX(generatedIndex)
  FROM `decentralizedanalysis.robinhood.robinhood_uniswapv3_pools`
);

IF max_gidx IS NULL THEN
  SET max_gidx = -1;
END IF;

INSERT INTO `decentralizedanalysis.robinhood.robinhood_uniswapv3_pools` (
  pool_address, token0, token1, fee, tickSpacing,
  block_date, block_hour, block_number, transaction_hash, log_index, generatedIndex
)
SELECT
  CONCAT('0x', SUBSTR(data, 91, 40))                          AS pool_address   -- data word 1: address
, CONCAT('0x', SUBSTR(topics[SAFE_OFFSET(1)], 27, 40))        AS token0         -- topic1: address
, CONCAT('0x', SUBSTR(topics[SAFE_OFFSET(2)], 27, 40))        AS token1         -- topic2: address
, CAST(udf.hex_to_uint(SUBSTR(topics[SAFE_OFFSET(3)], 3, 64)) AS INT64) AS fee  -- topic3: uint24
, CAST(udf.hex_to_int(SUBSTR(data, 3, 64)) AS INT64)          AS tickSpacing    -- data word 0: int24
, block_date
, block_hour
, block_number
, transaction_hash
, log_index
, generatedIndex
FROM `decentralizedanalysis.robinhood.robinhood_uniswapv3_raw_logs`
WHERE block_date >= max_date
  AND generatedIndex > max_gidx
  /* address then topic0: the raw table's clustering keys, in that order, so
     both prune blocks before they are read. Without the address filter this
     would scan the whole raw table. */
  AND address = '0x1f7d7550b1b028f7571e69a784071f0205fd2efa'
  /* UniswapV3Factory */
  AND topic0 = '0x783cca1c0412dd0d695e784568c96da2e9c22ff989357a2e8b1d9b2b4e6b7118'
  /* PoolCreated (index_topic_1 address token0, index_topic_2 address token1,
     index_topic_3 uint24 fee, int24 tickSpacing, address pool)
     fee 100 -> tickSpacing 1, 500 -> 10, 3000 -> 60, 10000 -> 200 */
  ;


/* ==== 2/4  swaps ======================================================== */

SET max_date = (
  SELECT MAX(block_date)
  FROM `decentralizedanalysis.robinhood.robinhood_uniswapv3_swaps`
  WHERE block_date > CURRENT_DATE() - INTERVAL 2 DAY
);

IF max_date IS NULL THEN
  SET max_date = (
    SELECT MAX(block_date)
    FROM `decentralizedanalysis.robinhood.robinhood_uniswapv3_swaps`
    WHERE block_date > DATE_TRUNC(CURRENT_DATE() - INTERVAL 30 DAY, MONTH)
  );
END IF;

IF max_date IS NULL THEN
  SET max_date = DATE '2026-05-22';
END IF;

SET max_gidx = (
  SELECT MAX(generatedIndex)
  FROM `decentralizedanalysis.robinhood.robinhood_uniswapv3_swaps`
  WHERE block_date >= max_date
);

IF max_gidx IS NULL THEN
  SET max_gidx = -1;
END IF;

INSERT INTO `decentralizedanalysis.robinhood.robinhood_uniswapv3_swaps` (
  block_date, block_hour, transaction_hash, pool_address, sender, recipient,
  amount0, amount1, sqrtPriceX96, liquidity, tick,
  block_number, transaction_index, log_index, generatedIndex, address, topics, data
)
SELECT
  block_date
, block_hour
, transaction_hash
, address                                                AS pool_address   -- the emitting contract IS the pool
, CONCAT('0x', SUBSTR(topics[SAFE_OFFSET(1)], 27, 40))   AS sender         -- topic1: address
, CONCAT('0x', SUBSTR(topics[SAFE_OFFSET(2)], 27, 40))   AS recipient      -- topic2: address
, udf.hex_to_int(SUBSTR(data, 3, 64))                    AS amount0        -- data word 0: int256
, udf.hex_to_int(SUBSTR(data, 67, 64))                   AS amount1        -- data word 1: int256
, udf.hex_to_uint_str(SUBSTR(data, 131, 64))             AS sqrtPriceX96   -- data word 2: uint160
, udf.hex_to_uint(SUBSTR(data, 195, 64))                 AS liquidity      -- data word 3: uint128
, udf.hex_to_int(SUBSTR(data, 259, 64))                  AS tick           -- data word 4: int24
, block_number, transaction_index, log_index
, generatedIndex
, address
, topics, data
FROM `decentralizedanalysis.robinhood.robinhood_uniswapv3_raw_logs`
WHERE block_date >= max_date
  AND generatedIndex > max_gidx
  AND topic0 = '0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67'
  /* Swap (index_topic_1 address sender, index_topic_2 address recipient,
     int256 amount0, int256 amount1, uint160 sqrtPriceX96, uint128 liquidity,
     int24 tick)
     amount0/amount1 are the POOL's side: positive = the pool received that
     token. This is the OPPOSITE of Uniswap v4, which reports the swapper's
     side. Anything comparing the two has to flip one of them. */
  ;


/* ==== 3/4  liquidity_movements ========================================== */
/* Mint and Burn in one table, with the NPM tokenId attached where the position
   was opened through the position manager.

   *** The data offsets are NOT the same for the two events. ***
   Mint carries `sender` as data word 0, so its liquidity is word 1. Burn has no
   sender, so its liquidity is word 0. Reusing one offset for both silently
   decodes an address as a liquidity amount. */

SET max_date = (
  SELECT MAX(block_date)
  FROM `decentralizedanalysis.robinhood.robinhood_uniswapv3_liquidity_movements`
  WHERE block_date > CURRENT_DATE() - INTERVAL 2 DAY
);

IF max_date IS NULL THEN
  SET max_date = (
    SELECT MAX(block_date)
    FROM `decentralizedanalysis.robinhood.robinhood_uniswapv3_liquidity_movements`
    WHERE block_date > DATE_TRUNC(CURRENT_DATE() - INTERVAL 30 DAY, MONTH)
  );
END IF;

IF max_date IS NULL THEN
  SET max_date = DATE '2026-05-22';
END IF;

SET max_gidx = (
  SELECT MAX(generatedIndex)
  FROM `decentralizedanalysis.robinhood.robinhood_uniswapv3_liquidity_movements`
  WHERE block_date >= max_date
);

IF max_gidx IS NULL THEN
  SET max_gidx = -1;
END IF;

INSERT INTO `decentralizedanalysis.robinhood.robinhood_uniswapv3_liquidity_movements` (
  block_date, block_hour, transaction_hash, pool_address, kind, tokenId, ownerAddress,
  tickLower, tickUpper, liquidityDelta, amount0, amount1,
  block_number, transaction_index, log_index, generatedIndex, address, topics, data
)
WITH npm AS (
  /* The position manager's own view of the same liquidity change. topic1 is the
     NFT id; data word 0 is the liquidity, which is what pairs it with the
     pool's Mint/Burn.

     Bounded by block_date only, NOT by max_gidx. The NPM event sits after the
     pool event in the same transaction, so every row this join needs is already
     past the cursor; adding the filter would prune nothing and would silently
     drop tokenIds if that ordering ever failed to hold. */
  SELECT block_date, transaction_hash, generatedIndex,
         topics[SAFE_OFFSET(1)]  AS tokenId,
         SUBSTR(data, 3, 64)     AS liq_hex,
         topic0
  FROM `decentralizedanalysis.robinhood.robinhood_uniswapv3_raw_logs`
  WHERE block_date >= max_date
    AND address = '0x73991a25c818bf1f1128deaab1492d45638de0d3'   -- NonfungiblePositionManager, a clustering key
    AND topic0 IN (
      '0x3067048beee31b25b2f1681f88dac838c8bba36af25bfb2b7cf7473a5847e35f',
      /* IncreaseLiquidity (index_topic_1 uint256 tokenId, uint128 liquidity,
         uint256 amount0, uint256 amount1) */
      '0x26f6a048ee9138f2c0ce266f322cb99228e8d619ae2bff30c67f8dcf9d2377b4')
      /* DecreaseLiquidity (index_topic_1 uint256 tokenId, uint128 liquidity,
         uint256 amount0, uint256 amount1) */
)
, moves AS (
  SELECT
    block_date, block_hour, transaction_hash, address AS pool_address
  , CASE WHEN topic0 = '0x7a53080ba414158be7ec69b987b5fb7d07dee101fe85488f0853ae16239d0bde' THEN 'mint' ELSE 'burn' END AS kind
  , CONCAT('0x', SUBSTR(topics[SAFE_OFFSET(1)], 27, 40)) AS ownerAddress
  , CAST(udf.hex_to_int(SUBSTR(topics[SAFE_OFFSET(2)], 3, 64)) AS INT64) AS tickLower
  , CAST(udf.hex_to_int(SUBSTR(topics[SAFE_OFFSET(3)], 3, 64)) AS INT64) AS tickUpper
    -- Mint has `sender` in data word 0, Burn does not: liquidity is word 1 for mint, word 0 for burn.
  , CASE WHEN topic0 = '0x7a53080ba414158be7ec69b987b5fb7d07dee101fe85488f0853ae16239d0bde'
         THEN  udf.hex_to_int(SUBSTR(data,  67, 64))
         ELSE -udf.hex_to_int(SUBSTR(data,   3, 64)) END AS liquidityDelta
  , CASE WHEN topic0 = '0x7a53080ba414158be7ec69b987b5fb7d07dee101fe85488f0853ae16239d0bde'
         THEN  udf.hex_to_int(SUBSTR(data, 131, 64))
         ELSE -udf.hex_to_int(SUBSTR(data,  67, 64)) END AS amount0
  , CASE WHEN topic0 = '0x7a53080ba414158be7ec69b987b5fb7d07dee101fe85488f0853ae16239d0bde'
         THEN  udf.hex_to_int(SUBSTR(data, 195, 64))
         ELSE -udf.hex_to_int(SUBSTR(data, 131, 64)) END AS amount1
    -- the liquidity word, as hex, for pairing with the NPM event
  , CASE WHEN topic0 = '0x7a53080ba414158be7ec69b987b5fb7d07dee101fe85488f0853ae16239d0bde'
         THEN SUBSTR(data, 67, 64) ELSE SUBSTR(data, 3, 64) END AS liq_hex
  , CASE WHEN topic0 = '0x7a53080ba414158be7ec69b987b5fb7d07dee101fe85488f0853ae16239d0bde'
         THEN '0x3067048beee31b25b2f1681f88dac838c8bba36af25bfb2b7cf7473a5847e35f'
         ELSE '0x26f6a048ee9138f2c0ce266f322cb99228e8d619ae2bff30c67f8dcf9d2377b4' END AS want_topic0
  , block_number, transaction_index, log_index, generatedIndex, address, topics, data
  FROM `decentralizedanalysis.robinhood.robinhood_uniswapv3_raw_logs`
  WHERE block_date >= max_date
    AND generatedIndex > max_gidx
    AND topic0 IN (
      '0x7a53080ba414158be7ec69b987b5fb7d07dee101fe85488f0853ae16239d0bde',
      /* Mint (address sender, index_topic_1 address owner,
         index_topic_2 int24 tickLower, index_topic_3 int24 tickUpper,
         uint128 amount, uint256 amount0, uint256 amount1) */
      '0x0c396cd989a39f4459b5fa1aed6a9a8dcdbc45908acfd67e028cd568da98982c')
      /* Burn (index_topic_1 address owner, index_topic_2 int24 tickLower,
         index_topic_3 int24 tickUpper, uint128 amount, uint256 amount0,
         uint256 amount1)
         83% of Burns have liquidityDelta = 0 -- burn(0) is the fee-update
         idiom and the NPM calls it inside collect(). Filter liquidityDelta != 0
         for anything about liquidity actually leaving a pool. */
)
SELECT
  m.block_date, m.block_hour, m.transaction_hash, m.pool_address, m.kind,
  n.tokenId, m.ownerAddress, m.tickLower, m.tickUpper,
  m.liquidityDelta, m.amount0, m.amount1,
  m.block_number, m.transaction_index, m.log_index, m.generatedIndex, m.address, m.topics, m.data
FROM moves m
LEFT JOIN npm n
  ON  n.transaction_hash = m.transaction_hash
  AND n.block_date       = m.block_date
  AND n.liq_hex          = m.liq_hex
  AND n.topic0           = m.want_topic0
  /* The NPM emits its event AFTER the pool's, in the same transaction. Without
     this, a transaction touching two positions with equal liquidity could pair
     the wrong one. */
  AND n.generatedIndex   > m.generatedIndex
/* Still possible for one pool event to match several NPM events (same tx, same
   liquidity): keep the nearest following one. */
QUALIFY ROW_NUMBER() OVER (PARTITION BY m.generatedIndex ORDER BY n.generatedIndex) = 1
  ;


/* ==== 4/4  collects ===================================================== */
/* *** This is the table TVL needs. *** A Burn does NOT move tokens out of a v3
   pool -- it credits tokensOwed. Collect is where tokens actually leave:

     balance(token0) = SUM(Mint.amount0) + SUM(Swap.amount0, pool side)
                       - SUM(Collect.amount0)

   Burn contributes nothing to it. amount0/amount1 are uint128 and always
   positive, so decode with hex_to_uint, not hex_to_int. */

SET max_date = (
  SELECT MAX(block_date)
  FROM `decentralizedanalysis.robinhood.robinhood_uniswapv3_collects`
  WHERE block_date > CURRENT_DATE() - INTERVAL 2 DAY
);

IF max_date IS NULL THEN
  SET max_date = (
    SELECT MAX(block_date)
    FROM `decentralizedanalysis.robinhood.robinhood_uniswapv3_collects`
    WHERE block_date > DATE_TRUNC(CURRENT_DATE() - INTERVAL 30 DAY, MONTH)
  );
END IF;

IF max_date IS NULL THEN
  SET max_date = DATE '2026-05-22';
END IF;

SET max_gidx = (
  SELECT MAX(generatedIndex)
  FROM `decentralizedanalysis.robinhood.robinhood_uniswapv3_collects`
  WHERE block_date >= max_date
);

IF max_gidx IS NULL THEN
  SET max_gidx = -1;
END IF;

INSERT INTO `decentralizedanalysis.robinhood.robinhood_uniswapv3_collects` (
  block_date, block_hour, transaction_hash, pool_address, tokenId, ownerAddress, recipient,
  tickLower, tickUpper, amount0, amount1,
  block_number, transaction_index, log_index, generatedIndex, address, topics, data
)
WITH npm_collect AS (
  /* The position manager's own Collect. topic1 is the NFT id. Bounded by
     block_date only, for the same reason as block 3's npm CTE. */
  SELECT block_date, transaction_hash, generatedIndex, topics[SAFE_OFFSET(1)] AS tokenId
  FROM `decentralizedanalysis.robinhood.robinhood_uniswapv3_raw_logs`
  WHERE block_date >= max_date
    AND address = '0x73991a25c818bf1f1128deaab1492d45638de0d3'   -- NonfungiblePositionManager, a clustering key
    AND topic0  = '0x40d0efd1a53d60ecbf40971b9daf7dc90178c3aadc7aab1765632738fa8b8f01'
    /* Collect (index_topic_1 uint256 tokenId, address recipient,
       uint256 amount0, uint256 amount1) -- the NPM's, not the pool's */
)
, pool_collect AS (
  SELECT
    block_date, block_hour, transaction_hash
  , address                                                AS pool_address
  , CONCAT('0x', SUBSTR(topics[SAFE_OFFSET(1)], 27, 40))   AS ownerAddress   -- topic1: address
  , CONCAT('0x', SUBSTR(data, 27, 40))                     AS recipient      -- data word 0: address
  , CAST(udf.hex_to_int(SUBSTR(topics[SAFE_OFFSET(2)], 3, 64)) AS INT64) AS tickLower  -- topic2: int24
  , CAST(udf.hex_to_int(SUBSTR(topics[SAFE_OFFSET(3)], 3, 64)) AS INT64) AS tickUpper  -- topic3: int24
  , udf.hex_to_uint(SUBSTR(data,  67, 64))                 AS amount0        -- data word 1: uint128
  , udf.hex_to_uint(SUBSTR(data, 131, 64))                 AS amount1        -- data word 2: uint128
  , block_number, transaction_index, log_index, generatedIndex, address, topics, data
  FROM `decentralizedanalysis.robinhood.robinhood_uniswapv3_raw_logs`
  WHERE block_date >= max_date
    AND generatedIndex > max_gidx
    AND topic0 = '0x70935338e69775456a85ddef226c395fb668b63fa0115f5f20610b388e6ca9c0'
    /* Collect (index_topic_1 address owner, address recipient,
       index_topic_2 int24 tickLower, index_topic_3 int24 tickUpper,
       uint128 amount0, uint128 amount1) -- the pool's */
)
SELECT
  c.block_date, c.block_hour, c.transaction_hash, c.pool_address, n.tokenId,
  c.ownerAddress, c.recipient, c.tickLower, c.tickUpper, c.amount0, c.amount1,
  c.block_number, c.transaction_index, c.log_index, c.generatedIndex, c.address, c.topics, c.data
FROM pool_collect c
LEFT JOIN npm_collect n
  ON  n.transaction_hash = c.transaction_hash
  AND n.block_date       = c.block_date
  /* The NPM emits its Collect after the pool's, in the same transaction. */
  AND n.generatedIndex   > c.generatedIndex
QUALIFY ROW_NUMBER() OVER (PARTITION BY c.generatedIndex ORDER BY n.generatedIndex) = 1
  ;
