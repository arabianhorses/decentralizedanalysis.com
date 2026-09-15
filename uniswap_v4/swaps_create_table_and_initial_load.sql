/*
There are 2 SQL scripts first one for creating the table and define the specs, second one for initial load

robinhood_uniswapv4_swaps
One row per Uniswap v4 swap on Robinhood Chain: every PoolManager(0x8366a39cc670b4001a1121b8f6a443a643e40951) Swap(0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f)
event.
Source: robinhood.robinhood_uniswapv4_raw_logs. (or however you call the logs)

amount0 / amount1 are from the swapper's side: negative = the swapper paid that token into the pool,
positive = the swapper received it. This is the opposite of Uniswap v3's Swap event.

Needs the UDFs in udf/hex_decoding_udfs.sql (run that first):
hex_to_int (amount0, amount1, tick), hex_to_uint (liquidity, fee), hex_to_uint_str (sqrtPriceX96).

*/
  CREATE TABLE `decentralizedanalysis.robinhood.robinhood_uniswapv4_swaps` (
  block_date        DATE       NOT NULL,
  transaction_hash  STRING     NOT NULL,
  poolId            STRING     NOT NULL  OPTIONS (description = "bytes32 PoolId, 0x-prefixed (topic1); joins to robinhood_uniswapv4_pool_initializations"),
  amount0           BIGNUMERIC           OPTIONS (description = "int128, swapper's side: negative = paid into the pool, positive = received. Opposite sign to Uniswap v3"),
  amount1           BIGNUMERIC           OPTIONS (description = "int128, swapper's side: negative = paid into the pool, positive = received. Opposite sign to Uniswap v3"),
  sqrtPriceX96      STRING               OPTIONS (description = "uint160 sqrt price after the swap, exact decimal. STRING because it can exceed BIGNUMERIC; CAST AS FLOAT64 for math"),
  liquidity         BIGNUMERIC           OPTIONS (description = "uint128 in-range liquidity after the swap"),
  tick              BIGNUMERIC           OPTIONS (description = "tick where swap ends"),
  fee               BIGNUMERIC           OPTIONS (description = "uint24 fee applied to this swap, hundredths of a bip"),
  sender            STRING               OPTIONS (description = "Caller of PoolManager.swap (topic2), usually a router, not the trader'swallet"),
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
  description =  "Uniswap v4 Swap events on Robinhood Chain, decoded. Built from robinhood_uniswapv4_raw_logs; SQL in uniswap_v4/ at github.com/arabianhorses/decentralizedanalysis.com."
);

-- First fill of robinhood_uniswapv4_swaps: every Swap before 2026-08-25 (this was last full day when we are generating this table).
-- Run once, on an empty table. The incremental query takes over from 2026-08-25.
INSERT INTO `decentralizedanalysis.robinhood.robinhood_uniswapv4_swaps` (
  block_date, transaction_hash, poolId, amount0, amount1, sqrtPriceX96, liquidity, tick, fee, sender,
  block_number, transaction_index, log_index, generatedIndex, address, topics, data
)
SELECT
  block_date
, transaction_hash
, topics[SAFE_OFFSET(1)] AS poolId
, udf.hex_to_int(SUBSTR(data, 3, 64)) AS amount0
, udf.hex_to_int(SUBSTR(data, 67, 64)) AS amount1
, udf.hex_to_uint_str(SUBSTR(data, 131, 64)) AS sqrtPriceX96
, udf.hex_to_uint(SUBSTR(data, 195, 64)) AS liquidity
, udf.hex_to_int(SUBSTR(data, 259, 64)) AS tick
, udf.hex_to_uint(SUBSTR(data, 323, 64)) AS fee
, CONCAT('0x', SUBSTR(topics[SAFE_OFFSET(2)], 27, 40)) AS sender
, block_number, transaction_index, log_index
, generatedIndex
, address
, topics, data
FROM `decentralizedanalysis.robinhood.robinhood_uniswapv4_raw_logs`
WHERE topic0 = '0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f'  -- Swap(bytes32 indexed id, address indexed sender, int128 amount0, int128 amount1, uint160 sqrtPriceX96, uint128 liquidity, int24 tick, uint24 fee)
  AND block_date < '2026-08-25';
