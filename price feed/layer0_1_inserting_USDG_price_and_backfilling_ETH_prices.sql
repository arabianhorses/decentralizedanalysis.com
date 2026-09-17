/*
I think it is clear with name layer0.1 adds USDG price into the table also backfilling price for ETH and WETH with
this line 
  , LAST_VALUE(price IGNORE NULLS) OVER (PARTITION BY tokenAddress ORDER BY hour) AS price

*/

MERGE `decentralizedanalysis.robinhood.robinhood_token_prices` T
USING (
  WITH
  anchors AS (
    SELECT token_address AS tokenAddress, symbol AS tokenSymbol, decimals AS tokenDecimals
    FROM `decentralizedanalysis.robinhood.token_mapping`
    WHERE token_address IN (
      '0x0000000000000000000000000000000000000000',
      '0x0bd7d308f8e1639fab988df18a8011f41eacad73',
      '0x5fc5360d0400a0fd4f2af552add042d716f1d168')
  ),
  hours AS (
    SELECT hour FROM UNNEST(GENERATE_TIMESTAMP_ARRAY(
      TIMESTAMP '2026-06-29 00:00:00+00', TIMESTAMP '2026-09-15 23:00:00+00',
      INTERVAL 1 HOUR)) AS hour
  ),
  spine AS (
    SELECT h.hour, a.tokenAddress, a.tokenSymbol, a.tokenDecimals
    FROM hours h CROSS JOIN anchors a
  )
  SELECT hour, tokenAddress, tokenSymbol, tokenDecimals
  , LAST_VALUE(price IGNORE NULLS) OVER (PARTITION BY tokenAddress ORDER BY hour) AS price
  FROM (
    SELECT spi.*
    , CASE WHEN spi.tokenAddress = '0x5fc5360d0400a0fd4f2af552add042d716f1d168'
           THEN 1.0 ELSE pri.price END AS price
    FROM spine spi
    LEFT JOIN `decentralizedanalysis.robinhood.robinhood_token_prices` pri
      ON spi.hour = pri.hour AND spi.tokenAddress = pri.tokenAddress
  )
) S
ON T.hour = S.hour AND T.tokenAddress = S.tokenAddress
WHEN NOT MATCHED AND S.price IS NOT NULL THEN
  INSERT (hour, tokenAddress, tokenSymbol, tokenDecimals, price)
  VALUES (S.hour, S.tokenAddress, S.tokenSymbol, S.tokenDecimals, S.price)
