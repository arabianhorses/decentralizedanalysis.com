/*
There are 2 SQL scripts first one for creating the table and define the specs, second one for initial load
, additionally you may find our incremental query for keeping the table updated


One row per Uniswap v3 swap on Robinhood Chain: every Swap(0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67)
event emitted by a pool the UniswapV3Factory(0x1f7d7550b1b028f7571e69a784071f0205fd2efa) created.

amount0 / amount1 are the POOL's side: positive = the pool received that token, negative =
the pool paid it out. This is the OPPOSITE of Uniswap v4, whose Swap reports the swapper's
side. Anything comparing the two protocols has to flip one of them, or every buy becomes a
sell.

sender and recipient are routers, not traders. On this chain they are almost always
UniversalRouter 0x8876789976decbfcbbbe364623c63652db8c0904 or SwapRouter02
0xcaf681a66d020601342297493863e78c959e5cb2.

Unlike v4 there is no poolId: the emitting contract IS the pool, so address is the pool and
joins to robinhood_uniswapv3_pools on pool_address.

No join is needed here to exclude the v3 forks (Ramses, Raphael, Giga, "up"). The raw table
is already Uniswap-only -- the ingestion drops any pool the factory did not create before
writing it, so a fork's Swap never reaches this table.

Needs the UDFs in (udf/hex_decoding_udfs.sql)[https://github.com/arabianhorses/decentralizedanalysis.com/blob/main/udf/hex_decoding_udfs.sql] **run that first**:
hex_to_int (amount0, amount1, tick), hex_to_uint (liquidity), hex_to_uint_str (sqrtPriceX96).

*/
  CREATE TABLE `decentralizedanalysis.robinhood.robinhood_uniswapv3_swaps` (
  block_date        DATE       NOT NULL,
  block_hour        TIMESTAMP           OPTIONS (description = "Start of the UTC hour containing this block, from robinhood.block_hours. This chain has no per-log timestamp; this is the finest time grain available"),
  transaction_hash  STRING     NOT NULL,
  pool_address      STRING     NOT NULL OPTIONS (description = "Emitting pool contract; joins to robinhood_uniswapv3_pools"),
  sender            STRING              OPTIONS (description = "Caller of the swap (topic1), a router, not the trader's wallet"),
  recipient         STRING              OPTIONS (description = "Who received the output (topic2), usually a router"),
  amount0           BIGNUMERIC          OPTIONS (description = "int256, the POOL's side: positive = pool received token0. Opposite sign to Uniswap v4"),
  amount1           BIGNUMERIC          OPTIONS (description = "int256, the POOL's side: positive = pool received token1. Opposite sign to Uniswap v4"),
  sqrtPriceX96      STRING              OPTIONS (description = "uint160 sqrt price after the swap, exact decimal. STRING because it can exceed BIGNUMERIC; CAST AS FLOAT64 for math"),
  liquidity         BIGNUMERIC          OPTIONS (description = "uint128 in-range liquidity after the swap"),
  tick              BIGNUMERIC          OPTIONS (description = "int24 tick after the swap"),
  block_number      INT64      NOT NULL,
  transaction_index INT64,
  log_index         INT64      NOT NULL,
  generatedIndex    INT64      NOT NULL OPTIONS (description = "block_number * 10^6 + log_index; unique row id and incremental cursor"),
  address           STRING     NOT NULL OPTIONS (description = "Same as pool_address; kept so the raw shape is preserved"),
  topics            ARRAY<STRING>,
  data              STRING
)
PARTITION BY block_date
CLUSTER BY pool_address
OPTIONS (
  require_partition_filter = TRUE,
  description = "Uniswap v3 Swap events on Robinhood Chain, decoded. Built from robinhood_uniswapv3_raw_logs; only pools created by UniswapV3Factory 0x1f7d7550b1b028f7571e69a784071f0205fd2efa. SQL in uniswap_v3/ at github.com/arabianhorses/decentralizedanalysis.com."
);

-- First fill of robinhood_uniswapv3_swaps: every Swap before 2026-07-09 (this was the last full day when we are generating this table).
-- Run once, on an empty table. The incremental query takes over from 2026-07-09.
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
WHERE topic0 = '0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67'  -- Swap (index_topic_1 address sender, index_topic_2 address recipient, int256 amount0, int256 amount1, uint160 sqrtPriceX96, uint128 liquidity, int24 tick)
  AND block_date < '2026-07-09';

---
