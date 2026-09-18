/*
## this script entirely written by claude code

hourly_price_feed_merge.sql -- the whole feed, one MERGE, parameterised.

Replaces price_feed_initial.sql (layer 0) and
layer1_claiming_token_prices_by_using_anchor_pairs.sql (layer 1), which were
INSERTs and therefore doubled their rows on a re-run.

Run it after every decoded-table sync, via sync/price_feed.py, which reads the
watermark free from INFORMATION_SCHEMA.PARTITIONS and passes it as a parameter.

  @from_date  DATE  first block_date to read (inclusive)
  @to_date    DATE  last  block_date to read (inclusive)

## Why parameters and not DECLARE/SET

DEVLOG 2026-09-16 trap 2: a variable SET from a subquery is unknown at planning
time, so the script cannot be priced -- the same shape reported 10 MB and 126 GB
against a true 82.8 GB. Query parameters prune exactly like literals and
dry-run honestly. There is no DECLARE in this file on purpose.

## Why MERGE and not INSERT + a generatedIndex cursor

The v3/v4 incrementals move a forward cursor because a decoded swap never
changes. A price DOES change: the same hour re-priced after more swaps land
gives a different median. So the key is (hour, tokenAddress) and the write is an
upsert, with WHEN NOT MATCHED BY SOURCE deleting rows in the window that no
longer qualify. That is what makes it a replace rather than an accumulate.

## Layers

  USDG = 1.00 by assertion, the only dollar anchor on this chain
    -> layer 0: ETH and WETH, from USDG-paired pools
    -> layer 1: everything else, from USDG/ETH/WETH-paired pools
    -> layer 2: the remainder, from a well-supported layer-1 token

ETH and WETH are priced as SEPARATE assets and never aliased -- decided in
chain/token_mapping.md and reaffirmed 2026-09-18. There is no canonical_address.

Layer 2 is capped at one hop and only chains off a layer-1 row carrying
>= MIN_SUPPORT swaps. Unbounded chaining is what produced the $12,283,426-per-
token anchor rows recorded in DEVLOG 2026-09-18.

## The floors, and which defect each one closes

  knownUsd >= 100      the priced leg must be worth $100. Closes the confirmed
                       CRCL case (0.0198 ETH ~= $38 against 5e-07 CRCL, which
                       the old `volumeUsd > 10` let through).
  unknownAmt > 1e-4    the OTHER leg must be a real amount. The old floors
                       constrained only the priced leg, which is exactly how a
                       dust counter-leg forged 34,180 ETH/CRCL.
  poolDaySwaps > 20    borrowed from the lpscanner feed. Cheap, and it drops
                       pools that traded once -- but it did NOT catch the
                       synthetic entries of 2026-09-18, which sat inside
                       pool-days of 63 to 1,405 swaps. Not a safety net.

v4 pools are additionally limited to fee > 0 and no hook. Those predicates are
in the v4 arm only: v3 has no hooks and never enabled a 0 fee tier, so the same
filter there would silently drop nothing while looking like it did something.

## Median, never mean

APPROX_QUANTILES(...)[OFFSET(1)] across every qualifying swap in the hour, one
vote per swap. DEVLOG 2026-09-17 measured the alternative: per-pool median then
volume-weighted mean made it WORSE, 274 bad rows vs 234, because stage 2 is a
weighted mean and a pool quoting 1e10 is added in rather than outvoted (TSLA
came out at $19.7bn). Do not reach for a mean here.

## Earliest priceable date is 2026-06-09

The first USDG-paired pool was created 2026-06-09 (v4) / 2026-06-11 (v3).
Swaps go back to 2026-05-22, but with no dollar anchor in existence there is
nothing to price against, so @from_date below 2026-06-09 buys only scanned bytes.
*/
MERGE `decentralizedanalysis.robinhood.robinhood_token_prices` AS target
USING (

WITH
tm AS (
  SELECT token_address, symbol, decimals
  FROM `decentralizedanalysis.robinhood.token_mapping`
),

/* One normalised leg table, so the two-sided price logic is written once
   instead of once per (protocol x which-side-is-known). */
legs AS (
  SELECT
    swa.block_date
  , swa.block_hour
  , swa.pool_address                        AS poolKey
  , pc.token0                               AS tk0
  , pc.token1                               AS tk1
  , ABS(CAST(swa.amount0 AS FLOAT64))       AS a0
  , ABS(CAST(swa.amount1 AS FLOAT64))       AS a1
  FROM `decentralizedanalysis.robinhood.robinhood_uniswapv3_swaps` swa
  JOIN `decentralizedanalysis.robinhood.robinhood_uniswapv3_pools` pc
    ON swa.pool_address = pc.pool_address
  WHERE swa.block_date BETWEEN @from_date AND @to_date
    AND swa.amount0 != 0
    AND swa.amount1 != 0

  UNION ALL

  SELECT
    swa.block_date
  , swa.block_hour
  , swa.poolId
  , pi.currency0
  , pi.currency1
  , ABS(CAST(swa.amount0 AS FLOAT64))
  , ABS(CAST(swa.amount1 AS FLOAT64))
  FROM `decentralizedanalysis.robinhood.robinhood_uniswapv4_swaps` swa
  JOIN `decentralizedanalysis.robinhood.robinhood_uniswapv4_pool_initializations` pi
    ON swa.poolId = pi.poolId
  WHERE swa.block_date BETWEEN @from_date AND @to_date
    AND swa.amount0 != 0
    AND swa.amount1 != 0
    AND pi.fee > 0
    AND pi.hookAddress = '0x0000000000000000000000000000000000000000'
),

/* Each swap becomes two directed rows: "given side A's price, here is B's".
   Every layer then joins its own known-price set to `knownAddr` and is one
   SELECT, not four. */
directed AS (
  SELECT
    block_hour AS hour, poolKey
  , COUNT(*) OVER (PARTITION BY poolKey, block_date) AS poolDaySwaps
  , tk0 AS knownAddr, a0 AS knownRaw, tk1 AS unknownAddr, a1 AS unknownRaw
  FROM legs
  UNION ALL
  SELECT
    block_hour, poolKey
  , COUNT(*) OVER (PARTITION BY poolKey, block_date)
  , tk1, a1, tk0, a0
  FROM legs
),

/* USDG = 1.00, one row per hour in the window, gapless by construction so
   nothing downstream has to cope with a missing anchor hour. */
usdg_px AS (
  SELECT
    h AS hour
  , '0x5fc5360d0400a0fd4f2af552add042d716f1d168' AS tokenAddress
  , 1.0 AS price
  , CAST(NULL AS INT64) AS swaps
  , 'L0:assert' AS priceSource
  FROM UNNEST(GENERATE_TIMESTAMP_ARRAY(
    TIMESTAMP(@from_date),
    TIMESTAMP_ADD(TIMESTAMP(@to_date), INTERVAL 23 HOUR),
    INTERVAL 1 HOUR)) AS h
),

/* ---- layer 0: ETH and WETH, from USDG ---------------------------------- */
layer0 AS (
  SELECT hour, unknownAddr AS tokenAddress
       , APPROX_QUANTILES(px, 2)[OFFSET(1)] AS price
       , COUNT(*) AS swaps
       , 'L0:USDG' AS priceSource
  FROM (
    SELECT
      d.hour, d.unknownAddr
    , (d.knownRaw / POW(10, 6)) * p.price                       AS knownUsd
    , d.unknownRaw / POW(10, u.decimals)                        AS unknownAmt
    , ((d.knownRaw / POW(10, 6)) * p.price)
      / (d.unknownRaw / POW(10, u.decimals))                    AS px
    , d.poolDaySwaps
    FROM directed d
    JOIN usdg_px p ON p.hour = d.hour AND p.tokenAddress = d.knownAddr
    JOIN tm u      ON u.token_address = d.unknownAddr
    WHERE d.unknownAddr IN ('0x0000000000000000000000000000000000000000',
                            '0x0bd7d308f8e1639fab988df18a8011f41eacad73')
  )
  WHERE knownUsd >= 100 AND unknownAmt > 1e-4 AND poolDaySwaps > 20
  GROUP BY 1, 2
),

anchor_px AS (
  SELECT hour, tokenAddress, price, swaps FROM usdg_px
  UNION ALL
  SELECT hour, tokenAddress, price, swaps FROM layer0
),

/* ---- layer 1: everything else, from USDG / ETH / WETH ------------------- */
layer1 AS (
  SELECT hour, unknownAddr AS tokenAddress
       , APPROX_QUANTILES(px, 2)[OFFSET(1)] AS price
       , COUNT(*) AS swaps
       , CONCAT('L1:', STRING_AGG(DISTINCT knownSym ORDER BY knownSym)) AS priceSource
  FROM (
    SELECT
      d.hour, d.unknownAddr
    , (d.knownRaw / POW(10, k.decimals)) * p.price              AS knownUsd
    , d.unknownRaw / POW(10, u.decimals)                        AS unknownAmt
    , ((d.knownRaw / POW(10, k.decimals)) * p.price)
      / (d.unknownRaw / POW(10, u.decimals))                    AS px
    , d.poolDaySwaps
    , k.symbol                                                  AS knownSym
    FROM directed d
    JOIN anchor_px p ON p.hour = d.hour AND p.tokenAddress = d.knownAddr
    JOIN tm k        ON k.token_address = d.knownAddr
    JOIN tm u        ON u.token_address = d.unknownAddr
    /* the priced side is an anchor, the other side is not */
    WHERE d.unknownAddr NOT IN ('0x0000000000000000000000000000000000000000',
                                '0x0bd7d308f8e1639fab988df18a8011f41eacad73',
                                '0x5fc5360d0400a0fd4f2af552add042d716f1d168')
  )
  WHERE knownUsd >= 100 AND unknownAmt > 1e-4 AND poolDaySwaps > 20
  GROUP BY 1, 2
),

/* Only a well-supported layer-1 row may act as a price source. */
layer1_strong AS (
  SELECT hour, tokenAddress, price FROM layer1 WHERE swaps >= 20
),

/* ---- layer 2: one hop only, off a well-supported layer-1 token ---------- */
layer2 AS (
  SELECT hour, unknownAddr AS tokenAddress
       , APPROX_QUANTILES(px, 2)[OFFSET(1)] AS price
       , COUNT(*) AS swaps
       , CONCAT('L2:', STRING_AGG(DISTINCT knownSym ORDER BY knownSym)) AS priceSource
  FROM (
    SELECT
      d.hour, d.unknownAddr
    , (d.knownRaw / POW(10, k.decimals)) * p.price              AS knownUsd
    , d.unknownRaw / POW(10, u.decimals)                        AS unknownAmt
    , ((d.knownRaw / POW(10, k.decimals)) * p.price)
      / (d.unknownRaw / POW(10, u.decimals))                    AS px
    , d.poolDaySwaps
    , k.symbol                                                  AS knownSym
    FROM directed d
    JOIN layer1_strong p ON p.hour = d.hour AND p.tokenAddress = d.knownAddr
    JOIN tm k            ON k.token_address = d.knownAddr
    JOIN tm u            ON u.token_address = d.unknownAddr
    /* Anti-join, not NOT EXISTS: a correlated subquery over another CTE is
       rejected here with "Correlated subqueries that reference other tables
       are not supported unless they can be de-correlated". */
    LEFT JOIN layer1 done
           ON done.hour = d.hour AND done.tokenAddress = d.unknownAddr
    WHERE d.unknownAddr NOT IN ('0x0000000000000000000000000000000000000000',
                                '0x0bd7d308f8e1639fab988df18a8011f41eacad73',
                                '0x5fc5360d0400a0fd4f2af552add042d716f1d168')
      /* do not re-price what layer 1 already priced */
      AND done.tokenAddress IS NULL
  )
  WHERE knownUsd >= 100 AND unknownAmt > 1e-4 AND poolDaySwaps > 20
  GROUP BY 1, 2
)

/* One row per (hour, token). A token cannot appear in two layers: layer 0 is
   ETH/WETH only, layer 1 excludes the anchors, layer 2 excludes anything
   layer 1 priced. */
SELECT
  a.hour
, a.tokenAddress
, t.symbol   AS tokenSymbol
, t.decimals AS tokenDecimals
, a.price
, a.swaps
, a.priceSource
FROM (
  SELECT hour, tokenAddress, price, swaps, priceSource FROM usdg_px
  UNION ALL SELECT hour, tokenAddress, price, swaps, priceSource FROM layer0
  UNION ALL SELECT hour, tokenAddress, price, swaps, priceSource FROM layer1
  UNION ALL SELECT hour, tokenAddress, price, swaps, priceSource FROM layer2
) a
JOIN tm t ON t.token_address = a.tokenAddress

) AS source
ON  target.hour         = source.hour
AND target.tokenAddress = source.tokenAddress

WHEN MATCHED THEN UPDATE SET
  tokenSymbol   = source.tokenSymbol,
  tokenDecimals = source.tokenDecimals,
  price         = source.price,
  swaps         = source.swaps,
  priceSource   = source.priceSource

WHEN NOT MATCHED BY TARGET THEN
  INSERT (hour, tokenAddress, tokenSymbol, tokenDecimals, price, swaps, priceSource)
  VALUES (source.hour, source.tokenAddress, source.tokenSymbol,
          source.tokenDecimals, source.price, source.swaps, source.priceSource)

/* This is what makes it a replace: a row inside the window that no longer
   qualifies under the new floors is removed, not left behind. Scoped to the
   window so history outside it is untouched. */
WHEN NOT MATCHED BY SOURCE
 AND target.hour >= TIMESTAMP(@from_date)
 AND target.hour <  TIMESTAMP_ADD(TIMESTAMP(@to_date), INTERVAL 1 DAY)
THEN DELETE
