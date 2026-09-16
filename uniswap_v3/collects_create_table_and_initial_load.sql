
/*
There are 2 SQL scripts first one for creating the table and define the specs, second one for initial load

One row per Uniswap v3 collect on Robinhood Chain: every Collect(0x70935338e69775456a85ddef226c395fb668b63fa0115f5f20610b388e6ca9c0)
emitted by a pool the UniswapV3Factory(0x1f7d7550b1b028f7571e69a784071f0205fd2efa) created.

  Collect (index_topic_1 address owner, address recipient, index_topic_2 int24 tickLower,
           index_topic_3 int24 tickUpper, uint128 amount0, uint128 amount1)

*** This is the table TVL needs. ***
A Burn does NOT move tokens out of a v3 pool. It converts liquidity into tokensOwed
credited to the position; the ERC-20s stay in the pool contract. Collect is the event where
tokens actually leave. So the pool's token balance is:

    balance(token0) = SUM(Mint.amount0) + SUM(Swap.amount0, pool side) - SUM(Collect.amount0)

Burn contributes nothing to it. Using Burn as a proxy for outflow is wrong by exactly that gap.

amount0 / amount1 are uint128 and always positive -- they are a withdrawal, and the
direction is implied. Decode them with hex_to_uint, not hex_to_int.

A collect carries both the principal freed by an earlier Burn and the fees accrued since.
Fees earned = Collect amount - the Burn amount it settles. A collect following burn(0)
(the standard fee-poke idiom) is pure fees.

tokenId comes from the position manager's own Collect
(0x40d0efd1a53d60ecbf40971b9daf7dc90178c3aadc7aab1765632738fa8b8f01,
Collect(uint256 indexed tokenId, address recipient, uint256 amount0, uint256 amount1))
in the same transaction. NULL when the position was not opened through the NPM.

ownerAddress is the owner as the POOL sees it, which is the NonfungiblePositionManager
(0x73991a25c818bf1f1128deaab1492d45638de0d3) for any NFT position -- not the LP's wallet.
recipient is who actually received the tokens, and is frequently the NPM too, which then
forwards them.

Needs the UDFs in udf/hex_decoding_udfs.sql (run that first):
hex_to_uint (amounts), hex_to_int (ticks).

*/
  CREATE TABLE `decentralizedanalysis.robinhood.robinhood_uniswapv3_collects` (
  block_date        DATE       NOT NULL,
  block_hour        TIMESTAMP           OPTIONS (description = "Start of the UTC hour containing this block, from robinhood.block_hours"),
  transaction_hash  STRING     NOT NULL,
  pool_address      STRING     NOT NULL OPTIONS (description = "Emitting pool contract; joins to robinhood_uniswapv3_pools"),
  tokenId           STRING              OPTIONS (description = "NonfungiblePositionManager NFT id as bytes32 hex, from the NPM's own Collect in the same transaction. NULL when the position was not opened through the NPM"),
  ownerAddress      STRING              OPTIONS (description = "Position owner as the POOL sees it (topic1). The NonfungiblePositionManager for any NFT position, not the LP's wallet"),
  recipient         STRING              OPTIONS (description = "Who received the tokens (data word 0). Often the NPM, which forwards them on"),
  tickLower         INT64               OPTIONS (description = "int24 lower tick of the position range (topic2)"),
  tickUpper         INT64               OPTIONS (description = "int24 upper tick of the position range (topic3)"),
  amount0           BIGNUMERIC          OPTIONS (description = "uint128 token0 withdrawn from the pool, always positive. Principal freed by an earlier Burn plus accrued fees"),
  amount1           BIGNUMERIC          OPTIONS (description = "uint128 token1 withdrawn from the pool, always positive"),
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
  description = "Uniswap v3 Collect events on Robinhood Chain, decoded. The only event where tokens actually leave a v3 pool, so this is what TVL and fee accounting are built from. Built from robinhood_uniswapv3_raw_logs; SQL in uniswap_v3/ at github.com/arabianhorses/decentralizedanalysis.com."
);

-- First fill of robinhood_uniswapv3_collects: every Collect before 2026-07-09 (this was the last full day when we are generating this table).
-- Run once, on an empty table. The incremental query takes over from 2026-07-09.
INSERT INTO `decentralizedanalysis.robinhood.robinhood_uniswapv3_collects` (
  block_date, block_hour, transaction_hash, pool_address, tokenId, ownerAddress, recipient,
  tickLower, tickUpper, amount0, amount1,
  block_number, transaction_index, log_index, generatedIndex, address, topics, data
)
WITH npm_collect AS (
  -- The position manager's own Collect. topic1 is the NFT id.
  SELECT block_date, transaction_hash, generatedIndex, topics[SAFE_OFFSET(1)] AS tokenId
  FROM `decentralizedanalysis.robinhood.robinhood_uniswapv3_raw_logs`
  WHERE block_date < '2026-07-09'
    AND address = '0x73991a25c818bf1f1128deaab1492d45638de0d3'   -- NonfungiblePositionManager, a clustering key
    AND topic0  = '0x40d0efd1a53d60ecbf40971b9daf7dc90178c3aadc7aab1765632738fa8b8f01'  -- Collect (index_topic_1 uint256 tokenId, address recipient, uint256 amount0, uint256 amount1)
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
  WHERE block_date < '2026-07-09'
    AND topic0 = '0x70935338e69775456a85ddef226c395fb668b63fa0115f5f20610b388e6ca9c0'  -- Collect (index_topic_1 address owner, address recipient, index_topic_2 int24 tickLower, index_topic_3 int24 tickUpper, uint128 amount0, uint128 amount1)
)
SELECT
  c.block_date, c.block_hour, c.transaction_hash, c.pool_address, n.tokenId,
  c.ownerAddress, c.recipient, c.tickLower, c.tickUpper, c.amount0, c.amount1,
  c.block_number, c.transaction_index, c.log_index, c.generatedIndex, c.address, c.topics, c.data
FROM pool_collect c
LEFT JOIN npm_collect n
  ON  n.transaction_hash = c.transaction_hash
  AND n.block_date       = c.block_date
  -- The NPM emits its Collect after the pool's, in the same transaction.
  AND n.generatedIndex   > c.generatedIndex
QUALIFY ROW_NUMBER() OVER (PARTITION BY c.generatedIndex ORDER BY n.generatedIndex) = 1;

