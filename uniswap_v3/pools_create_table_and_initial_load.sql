uniswap_v3/pools_create_table_and_initial_load.sql

/*
There are 2 SQL scripts first one for creating the table and define the specs, second one for initial load, 
additionally you may find our incremental query for keeping the table updated.

robinhood_uniswapv3_pools
One row per Uniswap v3 pool on Robinhood Chain: every UniswapV3Factory(0x1f7d7550b1b028f7571e69a784071f0205fd2efa) 
PoolCreated(0x783cca1c0412dd0d695e784568c96da2e9c22ff989357a2e8b1d9b2b4e6b7118)
event.

fee is in hundredths of a bip: 100 = 0.01%, 500 = 0.05%, 3000 = 0.30%, 10000 = 1.00%.
tickSpacing is implied by fee (100 -> 1, 500 -> 10, 3000 -> 60, 10000 -> 200), so a row
where the two disagree is worth a look.



Unlike every other table in this repo it is NOT partitioned. It is a dimension table
joined on pool_address, and a pool's creation date has nothing to do with the dates of the
swaps referencing it, so partitioning by block_date would force every join to scan all
partitions anyway. ~432k rows is small enough that clustering alone does the work.

Needs the UDFs in [udf/hex_decoding_udfs.sql](https://github.com/arabianhorses/decentralizedanalysis.com/blob/main/udf/hex_decoding_udfs.sql):
hex_to_uint (fee), hex_to_int (tickSpacing).

*/
  CREATE TABLE `decentralizedanalysis.robinhood.robinhood_uniswapv3_pools` (
  pool_address      STRING    NOT NULL OPTIONS (description = "The pool contract, lowercase. Join key for swaps and liquidity movements"),
  token0            STRING    NOT NULL OPTIONS (description = "Lower-sorted token (topic1)"),
  token1            STRING    NOT NULL OPTIONS (description = "Higher-sorted token (topic2)"),
  fee               INT64              OPTIONS (description = "uint24 LP fee in hundredths of a bip: 3000 = 0.30%"),
  tickSpacing       INT64              OPTIONS (description = "int24, implied by fee"),
  block_date        DATE      NOT NULL OPTIONS (description = "UTC date the pool was created"),
  block_hour        TIMESTAMP          OPTIONS (description = "UTC hour the pool was created, from robinhood.block_hours"),
  block_number      INT64     NOT NULL,
  transaction_hash  STRING,
  log_index         INT64,
  generatedIndex    INT64     NOT NULL  OPTIONS (description = "block_number * 10^6 + log_index; unique row id and incremental cursor")
)
CLUSTER BY pool_address
OPTIONS (
  description = "Uniswap v3 pools on Robinhood Chain, decoded from UniswapV3Factory PoolCreated events. Dimension table: unpartitioned, clustered on pool_address. Built from robinhood_uniswapv3_raw_logs; SQL in uniswap_v3/ at github.com/arabianhorses/decentralizedanalysis.com."
);

-- First fill of robinhood_uniswapv3_pools: every PoolCreated before 2026-07-09 (this was the last full day when we are generating this table).
-- Run once, on an empty table. The incremental query takes over from 2026-07-09.
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
WHERE address = '0x1f7d7550b1b028f7571e69a784071f0205fd2efa'  -- UniswapV3Factory. A clustering key on the raw table, so this prunes before reading
  AND topic0 = '0x783cca1c0412dd0d695e784568c96da2e9c22ff989357a2e8b1d9b2b4e6b7118'  -- PoolCreated (index_topic_1 address token0, index_topic_2 address token1, index_topic_3 uint24 fee, int24 tickSpacing, address pool)
  AND block_date < '2026-07-09';



