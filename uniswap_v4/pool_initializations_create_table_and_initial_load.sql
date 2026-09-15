/*
There are 2 SQL scripts first one for creating the table and define the specs, second one for initial load, additionally you may find our incremental query for keeping the table updated

robinhood_uniswapv4_pool_initializations
One row per Uniswap v4 pool on Robinhood Chain: every PoolManager(0x8366a39cc670b4001a1121b8f6a443a643e40951) Initialize(0xdd466e674ea557f56295e2d0218a125ea4b4f0f6f3307b95f85e6110838d6438)
event.
Source: robinhood.robinhood_uniswapv4_raw_logs. (or however you call the logs)

Needs the UDFs in udf/hex_decoding_udfs.sql (run that first):
hex_to_uint (fee), hex_to_int (tickSpacing, tick), hex_to_uint_str (sqrtPriceX96).

*/
  CREATE TABLE `decentralizedanalysis.robinhood.robinhood_uniswapv4_pool_initializations` (
  block_date        DATE       NOT NULL,
  transaction_hash  STRING     NOT NULL,
  poolId            STRING     NOT NULL OPTIONS (description = "bytes32 PoolId, 0x-prefixed (topic1)"),
  currency0         STRING               OPTIONS (description = "Lower-sorted currency, 0x0 for native ETH (topic2)"),
  currency1         STRING               OPTIONS (description = "Higher-sorted currency (topic3)"),
  fee               BIGNUMERIC           OPTIONS (description = "uint24 LP fee in hundredths of a bip; 0x800000 flags a dynamic fee"),
  tickSpacing       BIGNUMERIC           OPTIONS (description = "int24"),
  hookAddress       STRING               OPTIONS (description = "Hooks contract, 0x0 when none"),
  sqrtPriceX96      STRING               OPTIONS (description = "uint160 initial sqrt price, exact decimal. STRING because it can exceed BIGNUMERIC; CAST AS FLOAT64 for math"),
  tick              BIGNUMERIC           OPTIONS (description = "int24 initial tick"),
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
  description = "Uniswap v4 Initialize events (pool creations) on Robinhood Chain, decoded. Built from robinhood_uniswapv4_raw_logs; SQL in uniswap_v4/robinhood/pool_initializations/."
);

-- First fill of robinhood_uniswapv4_pool_initializations: every Initialize before 2026-08-25 (this was last full day when we are generating this table).
-- Run once, on an empty table. incremental.sql takes over from 2026-08-25.
INSERT INTO `decentralizedanalysis.robinhood.robinhood_uniswapv4_pool_initializations` (
  block_date, transaction_hash, poolId, currency0, currency1, fee, tickSpacing, hookAddress,
  sqrtPriceX96, tick, block_number, transaction_index, log_index, generatedIndex, address, topics, data
)
SELECT
  block_date
, transaction_hash
, topics[SAFE_OFFSET(1)] AS poolId
, CONCAT('0x', SUBSTR(topics[SAFE_OFFSET(2)], 27, 40)) AS currency0
, CONCAT('0x', SUBSTR(topics[SAFE_OFFSET(3)], 27, 40)) AS currency1
, udf.hex_to_uint(SUBSTR(data, 3, 64)) AS fee
, udf.hex_to_int(SUBSTR(data, 67, 64)) AS tickSpacing
, CONCAT('0x', SUBSTR(data, 155, 40)) AS hookAddress
, udf.hex_to_uint_str(SUBSTR(data, 195, 64)) AS sqrtPriceX96
, udf.hex_to_int(SUBSTR(data, 259, 64)) AS tick
, block_number, transaction_index, log_index
, generatedIndex
, address
, topics, data
FROM `decentralizedanalysis.robinhood.robinhood_uniswapv4_raw_logs`
WHERE topic0 = '0xdd466e674ea557f56295e2d0218a125ea4b4f0f6f3307b95f85e6110838d6438'  -- Initialize(bytes32 indexed id, address indexed currency0, address indexed currency1, uint24 fee, int24 tickSpacing, address hooks, uint160 sqrtPriceX96, int24 tick)
  AND block_date < '2026-08-25';
