/*
There are 2 SQL scripts first one for creating the table and define the specs, second one for initial load

robinhood_uniswapv4_liquidity_modifications

One row per Uniswap v4 liquidity change on Robinhood Chain: every PoolManager(0x8366a39cc670b4001a1121b8f6a443a643e40951) 
ModifyLiquidity(0xf208f4912782fd25c7f114ca3723a2d5dd6f3bcc3ac8db5af63baa85f711d5ec) event.

liquidityDelta > 0 adds liquidity, < 0 removes it, = 0 only collects fees (v4 has no separate Collect event).
When sender is the PositionManager (0x58daec3116aae6d93017baaea7749052e8a04fa7), salt is the position NFT tokenId as bytes32:
the same hex as topic3 of that PositionManager's ERC-721 Transfer events, so the two join directly on it.

*/
  CREATE TABLE `decentralizedanalysis.robinhood.robinhood_uniswapv4_liquidity_modifications` (
  block_date        DATE       NOT NULL,
  transaction_hash  STRING     NOT NULL,
  poolId            STRING     NOT NULL  OPTIONS (description = "bytes32 PoolId, 0x-prefixed (topic1); joins to robinhood_uniswapv4_pool_initializations"),
  tickLower         BIGNUMERIC           OPTIONS (description = "int24 lower tick of the position range"),
  tickUpper         BIGNUMERIC           OPTIONS (description = "int24 upper tick of the position range"),
  liquidityDelta    BIGNUMERIC           OPTIONS (description = "int256: > 0 liquidity added, < 0 removed, = 0 fees collected only"),
  salt              STRING               OPTIONS (description = "bytes32 position salt, 0x-prefixed. The position NFT tokenId when sender is PositionManager; same hex as its Transfer topic3"),
  sender            STRING               OPTIONS (description = "Caller of PoolManager.modifyLiquidity (topic2), usually PositionManager, not the LP's wallet"),
  block_number      INT64      NOT NULL,
  transaction_index INT64,
  log_index         INT64      NOT NULL,
  generatedIndex    INT64      NOT NULL  OPTIONS (description = "block_number * 10^6 + log_index; unique row id and MERGE key"),
  address           STRING     NOT NULL  OPTIONS (description = "Emitting contract (PoolManager)"),
  topics            ARRAY<STRING>,
  data              STRING
)
PARTITION BY block_date
CLUSTER BY poolId
OPTIONS (
  require_partition_filter = TRUE,
  description = "Uniswap v4 ModifyLiquidity events on Robinhood Chain, decoded. Built from robinhood_uniswapv4_raw_logs; SQL in uniswap_v4/ at github.com/arabianhorses/decentralizedanalysis.com."
);

-- First fill of robinhood_uniswapv4_liquidity_modifications: every ModifyLiquidity before 2026-08-25 (same cutoff as pool_initializations and swaps).
-- Run once, on an empty table. The incremental query takes over from 2026-08-25.
INSERT INTO `decentralizedanalysis.robinhood.robinhood_uniswapv4_liquidity_modifications` (
  block_date, transaction_hash, poolId, tickLower, tickUpper, liquidityDelta, salt, sender,
  block_number, transaction_index, log_index, generatedIndex, address, topics, data
)
SELECT
  block_date
, transaction_hash
, topics[SAFE_OFFSET(1)] AS poolId
, udf.hex_to_int(SUBSTR(data, 3, 64)) AS tickLower
, udf.hex_to_int(SUBSTR(data, 67, 64)) AS tickUpper
, udf.hex_to_int(SUBSTR(data, 131, 64)) AS liquidityDelta
, CONCAT('0x', SUBSTR(data, 195, 64)) AS salt
, CONCAT('0x', SUBSTR(topics[SAFE_OFFSET(2)], 27, 40)) AS sender
, block_number, transaction_index, log_index
, generatedIndex
, address
, topics, data
FROM `decentralizedanalysis.robinhood.robinhood_uniswapv4_raw_logs`
WHERE topic0 = '0xf208f4912782fd25c7f114ca3723a2d5dd6f3bcc3ac8db5af63baa85f711d5ec'  -- ModifyLiquidity(bytes32 indexed id, address indexed sender, int24 tickLower, int24 tickUpper, int256 liquidityDelta, bytes32 salt)
  AND block_date < '2026-08-25';
