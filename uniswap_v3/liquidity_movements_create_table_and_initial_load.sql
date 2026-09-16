/*
There are 2 SQL scripts first one for creating the table and define the specs, second one for initial load
, additionally you may find our incremental query for keeping the table updated

One row per Uniswap v3 liquidity change on Robinhood Chain: every Mint(0x7a53080ba414158be7ec69b987b5fb7d07dee101fe85488f0853ae16239d0bde)
and Burn(0x0c396cd989a39f4459b5fa1aed6a9a8dcdbc45908acfd67e028cd568da98982c) emitted by a pool the
UniswapV3Factory(0x1f7d7550b1b028f7571e69a784071f0205fd2efa) created.

liquidityDelta > 0 for a Mint, < 0 for a Burn, so SUM(liquidityDelta) over a position gives
its current liquidity. amount0 / amount1 follow the same sign.

  Mint (address sender, index_topic_1 address owner, index_topic_2 int24 tickLower,
        index_topic_3 int24 tickUpper, uint128 amount, uint256 amount0, uint256 amount1)
  Burn (index_topic_1 address owner, index_topic_2 int24 tickLower,
        index_topic_3 int24 tickUpper, uint128 amount, uint256 amount0, uint256 amount1)

  *** The data offsets are NOT the same for the two events. ***
  Mint carries `sender` as data word 0, so its liquidity is word 1 (SUBSTR(data, 67, 64)).
  Burn has no sender, so its liquidity is word 0 (SUBSTR(data, 3, 64))

Collect is deliberately NOT in this table. In v3 a Burn moves liquidity into "owed" and
Collect is the actual transfer out, carrying the burned principal AND the accrued fees. If
both lived here with amount0/amount1 populated, SUM(amount0) would count the same
withdrawal twice. Collect has its own table; fees are Collect minus the matching Burn.

*** Most Burns remove no liquidity. ***
83% of Burn events on this chain (20,419 of 24,596 in the first fill) have liquidityDelta =
0. burn(0) is the standard v3 idiom for forcing a fee update, and the position manager calls
it inside collect(). Counting Burn rows as liquidity removals overstates them ~5x; filter
liquidityDelta != 0 for anything about liquidity leaving a pool.

tokenId is the NonfungiblePositionManager(0x73991a25c818bf1f1128deaab1492d45638de0d3) NFT
that owns the position, recovered by pairing the pool event with the NPM's
IncreaseLiquidity / DecreaseLiquidity in the same transaction on the liquidity amount. It is
NULL when liquidity was added directly to the pool rather than through the NonFungiblePositionManager.

Measured fill rate on the first fill, which is what a correct pairing looks like:
  mint                      100% of NPM-owned mints matched (24,993 of 24,993);
                            the 4,113 unmatched are positions opened directly on the pool
  burn, liquidityDelta != 0 100% matched (4,177 of 4,177)
  burn, liquidityDelta  = 0 0% matched, correctly -- a fee poke emits Collect, never
                            DecreaseLiquidity, so there is nothing to pair with

ownerAddress is the position's owner *as the pool sees it*, which is the NPM itself for any
NFT position -- not the wallet. The wallet comes from the NPM's ERC-721 Transfer events for
that tokenId.

Needs the UDFs in udf/hex_decoding_udfs.sql (run that first):
hex_to_int (ticks, liquidity, amounts).

*/
  CREATE TABLE `decentralizedanalysis.robinhood.robinhood_uniswapv3_liquidity_movements` (
  block_date        DATE       NOT NULL,
  block_hour        TIMESTAMP           OPTIONS (description = "Start of the UTC hour containing this block, from robinhood.block_hours"),
  transaction_hash  STRING     NOT NULL,
  pool_address      STRING     NOT NULL OPTIONS (description = "Emitting pool contract; joins to robinhood_uniswapv3_pools"),
  kind              STRING     NOT NULL OPTIONS (description = "'mint' or 'burn'"),
  tokenId           STRING              OPTIONS (description = "NonfungiblePositionManager NFT id as bytes32 hex, from the paired IncreaseLiquidity/DecreaseLiquidity. NULL when the position was not opened through the NPM"),
  ownerAddress      STRING              OPTIONS (description = "Position owner as the POOL sees it (topic1). This is the NonfungiblePositionManager for any NFT position, not the LP's wallet"),
  tickLower         INT64               OPTIONS (description = "int24 lower tick of the position range (topic2)"),
  tickUpper         INT64               OPTIONS (description = "int24 upper tick of the position range (topic3)"),
  liquidityDelta    BIGNUMERIC          OPTIONS (description = "uint128 magnitude, signed here: positive for mint, negative for burn"),
  amount0           BIGNUMERIC          OPTIONS (description = "token0 moved, signed to match liquidityDelta"),
  amount1           BIGNUMERIC          OPTIONS (description = "token1 moved, signed to match liquidityDelta"),
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
  description = "Uniswap v3 Mint and Burn events on Robinhood Chain, decoded, with the NonfungiblePositionManager tokenId attached where the position was opened through it. Built from robinhood_uniswapv3_raw_logs; SQL in uniswap_v3/ at github.com/arabianhorses/decentralizedanalysis.com."
);

-- First fill of robinhood_uniswapv3_liquidity_movements: every Mint and Burn before 2026-07-09 (this was the last full day when we are generating this table).
-- Run once, on an empty table. The incremental query takes over from 2026-07-09.
INSERT INTO `decentralizedanalysis.robinhood.robinhood_uniswapv3_liquidity_movements` (
  block_date, block_hour, transaction_hash, pool_address, kind, tokenId, ownerAddress,
  tickLower, tickUpper, liquidityDelta, amount0, amount1,
  block_number, transaction_index, log_index, generatedIndex, address, topics, data
)
WITH npm AS (
  -- The position manager's own view of the same liquidity change. topic1 is the NFT id;
  -- data word 0 is the liquidity, which is what pairs it with the pool's Mint/Burn.
  SELECT block_date, transaction_hash, generatedIndex, log_index,
         topics[SAFE_OFFSET(1)]  AS tokenId,
         SUBSTR(data, 3, 64)     AS liq_hex,
         topic0
  FROM `decentralizedanalysis.robinhood.robinhood_uniswapv3_raw_logs`
  WHERE block_date < '2026-07-09'
    AND address = '0x73991a25c818bf1f1128deaab1492d45638de0d3'   -- NonfungiblePositionManager, a clustering key
    AND topic0 IN (
      '0x3067048beee31b25b2f1681f88dac838c8bba36af25bfb2b7cf7473a5847e35f',  -- IncreaseLiquidity (index_topic_1 uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
      '0x26f6a048ee9138f2c0ce266f322cb99228e8d619ae2bff30c67f8dcf9d2377b4')  -- DecreaseLiquidity (index_topic_1 uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
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
  WHERE block_date < '2026-07-09'
    AND topic0 IN (
      '0x7a53080ba414158be7ec69b987b5fb7d07dee101fe85488f0853ae16239d0bde',  -- Mint
      '0x0c396cd989a39f4459b5fa1aed6a9a8dcdbc45908acfd67e028cd568da98982c')  -- Burn
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
  -- The NPM emits its event AFTER the pool's, in the same transaction. Without this, a
  -- transaction touching two positions with equal liquidity could pair the wrong one.
  AND n.generatedIndex   > m.generatedIndex
-- Still possible for one pool event to match several NPM events (same tx, same liquidity):
-- keep the nearest following one.
QUALIFY ROW_NUMBER() OVER (PARTITION BY m.generatedIndex ORDER BY n.generatedIndex) = 1;

