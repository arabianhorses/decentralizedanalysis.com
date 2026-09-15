/*
Hex decoding UDFs used by every decoded table in this repo.
Three functions in one file, in the order they must be created (hex_to_int calls hex_to_uint).

Before running: create a dataset named `udf` (US region), and replace every `decentralizedanalysis`
below with your own project id.

Which one to use:
  udf.hex_to_uint      uintN that fit BIGNUMERIC: fee, liquidity                      -> BIGNUMERIC, NULL above ~5.79e38
  udf.hex_to_int       intN (two's complement): tick, tiityDelta -> BIGNUMERIC
  udf.hex_to_uint_str  uintN that can exceed BIGNUMERIC: sqrtPriceX96                 -> exact decimal STRING
*/

-- hex_to_uint: ABI word (hex) -> unsigned integer, exac
--   udf.hex_to_uint('0000000000000000000000000000000000000000000000000000000000000bb8') = 3000
-- Accepts up to 64 hex digits, with or without 0x, any
-- Returns BIGNUMERIC, whose integer range tops out near 5.79e38 (about 2^128): values above
-- that come back NULL rather than failing the query. En28
-- liquidity and real token amounts; a uint160 sqrtPriceX96 of a pool with an extreme price
-- can exceed it (use hex_to_uint_str for that).
-- How: left-pad to 75 digits, read 5 chunks of 15 hex digits (60 bits, so each fits a
-- signed INT64), and combine them as ((((c0*2^60 + c1)* + c4).
-- SAFE_ arithmetic turns overflow into NULL.
CREATE OR REPLACE FUNCTION `decentralizedanalysis.udf.he
RETURNS BIGNUMERIC
OPTIONS (description = "ABI hex word (<=64 digits, optior. Exact; NULL when above BIGNUMERIC range (~5.79e38).Source: udf/hex_decoding_udfs.sql")
AS ((
  SELECT
    IF(LENGTH(h) > 64,
       ERROR(CONCAT('hex_to_uint: more than 64 hex digits: ', hex)),
       SAFE_ADD(SAFE_MULTIPLY(
         SAFE_ADD(SAFE_MULTIPLY(
           SAFE_ADD(SAFE_MULTIPLY(
             SAFE_ADD(SAFE_MULTIPLY(
               CAST(CAST(CONCAT('0x', SUBSTR(p,  1, 15)) 1152921504606846976),
               CAST(CAST(CONCAT('0x', SUBSTR(p, 16, 15)) AS INT64) AS BIGNUMERIC)), 1152921504606846976),
             CAST(CAST(CONCAT('0x', SUBSTR(p, 31, 15)) A1152921504606846976),
           CAST(CAST(CONCAT('0x', SUBSTR(p, 46, 15)) AS INT64) AS BIGNUMERIC)), 1152921504606846976),
         CAST(CAST(CONCAT('0x', SUBSTR(p, 61, 15)) AS IN
  FROM (
    SELECT h, LPAD(h, 75, '0') AS p
    FROM (SELECT REGEXP_REPLACE(LOWER(hex), r'^0x', '') AS h)
  )
));

-- hex_to_int: ABI word (hex) -> signed integer (two's complement), exact.
--   udf.hex_to_int('fffffffffffffffffffffffffffffffffff64b') = -203189
-- Use for every intN field: int24 tick / tickSpacing, int128 amount0 / amount1, int256
-- liquidityDelta. Use hex_to_uint for uintN.
-- Pass the FULL 64-digit word: the ABI sign-extends signed values to 256 bits, so the sign
-- is the top bit of the word. A shorter input cannot capositive.
-- Negative: -(bitwise NOT(x) + 1), where NOT on hex maps each digit d to 15 - d.
-- Returns BIGNUMERIC; values beyond about +/-5.79e38 cos fits).
CREATE OR REPLACE FUNCTION `decentralizedanalysis.udf.hex_to_int`(hex STRING)
RETURNS BIGNUMERIC
OPTIONS (description = "ABI hex word (full 64 digits, optional 0x) to signed integer, two's complement. Exact; NULL beyond BIGNUMERIC range. Source: udf/hex_decoding_udfs.sql")
AS ((
  SELECT
    IF(LENGTH(h) = 64 AND SUBSTR(h, 1, 1) IN ('8', '9', 'a', 'b', 'c', 'd', 'e', 'f'),
       -(`decentralizedanalysis.udf.hex_to_uint`(TRANSLA'fedcba9876543210')) + 1),
       `decentralizedanalysis.udf.hex_to_uint`(h))
  FROM (SELECT REGEXP_REPLACE(LOWER(hex), r'^0x', '') AS
));

-- hex_to_uint_str: ABI word (hex) -> exact unsigned integer as a decimal STRING. Full uint256.
--   udf.hex_to_uint_str('0000000000000000000000000000001c3de463') = '30835800255696290175924606657176436335715'
-- For fields that can exceed BIGNUMERIC's ~5.79e38, chiefly uint160 sqrtPriceX96: any pair with a
-- raw price above ~5.3e19 overflows (e.g. a cheap 18-demal USDC or
-- 8-decimal WBTC).
-- For math: CAST(x AS FLOAT64) (about 16 significant diIGNUMERIC) when
-- the value fits.
CREATE OR REPLACE FUNCTION `decentralizedanalysis.udf.he
RETURNS STRING
LANGUAGE js
OPTIONS (description = "ABI hex word (<=64 digits, optional 0x) to exact unsigned decimal STRING, full uint256. Source:
udf/hex_decoding_udfs.sql")
AS r"""
  if (hex === null || hex === undefined) return null;
  const h = hex.toLowerCase().replace(/^0x/, '');
  if (h.length === 0) return '0';
  if (h.length > 64 || !/^[0-9a-f]+$/.test(h)) throw new Error('hex_to_uint_str: not a <=64-digit hex word: ' + hex);
  return BigInt('0x' + h).toString();
""";
