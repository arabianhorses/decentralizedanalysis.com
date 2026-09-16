/*
One row per token we are willing to give place into our price feed.
Chain-level, not protocol-level: the price feed reads it once and both Uniswap v3 and v4 flow through it.

OK This is a hardcoded table which we are going to list some tokens and their details, then we are going to use this 
list as a filter in some queries, like for naming uniswap_pools tk0/tk1 -> I mean symbols of it. Also filtering 
price discovery query with these tokens in the list.

First we added tokenized stocks and USDG,ETH,WETH 

Seed contents (206 rows):

  USDG    0x5fc5360d0400a0fd4f2af552add042d716f1d168   6 decimals, is_dollar_pegged
  ETH     0x0000000000000000000000000000000000000000  18, native, no contract to call
  WETH    0x0bd7d308f8e1639fab988df18a8011f41eacad73  18
  203 x   Robinhood tokenized stocks, tag 'RH-TokenizedStock'

The tokenized-stock registry is regenerable on-chain in under a minute, so the
legacy robinhood-chain.robinhood_chain.robinhood_stock_tokens table (203 rows,
stops at block 21,689,593) is not worth preserving:

  contract  0x4783c67b63de2b358ac5951a7d41f47a38f3c046
  topic0    0xd9b0c6a1c0de228715ad0fa09f3259686ee84f8cc675e03ef7e47a9cdafa76d6
  layout    topic1 = stockTokenUid, data[0] = token address, then name and
            symbol as dynamic strings

It yields 204 entries. PEACH_DEFI_1 (block 58,748,161) is excluded here: it is in
the registry but is a test token, not an equity, so the table carries 203.

symbol and name come from eth_call, NOT from the registry's announcement strings.
They agree for 197 of 203; the six that differ have a fuller legal name on-chain
(SpaceX announces as "SpaceX • Robinhood Token" and calls itself "Space
Exploration Technologies Corp. Class A Common Stock • Robinhood Token"). The
contract is the authority.



Built and refreshed by sync/token_mapping.py. Loads are from local files, which
are free.
*/
CREATE TABLE IF NOT EXISTS `decentralizedanalysis.robinhood.token_mapping` (
  token_address     STRING    NOT NULL OPTIONS (description = "Lowercase contract address, the join key. 0x0000...0000 is native ETH, which is not a contract"),
  symbol            STRING             OPTIONS (description = "eth_call symbol(). Hand-set for native ETH"),
  name              STRING             OPTIONS (description = "eth_call name(). Hand-set for native ETH. Authoritative over any announcement string"),
  decimals          INT64              OPTIONS (description = "eth_call decimals(). Price math is silently wrong without it"),
  is_dollar_pegged  BOOL               OPTIONS (description = "Hand-curated. USDG only, today. The feed's hop-0 anchor"),
  tags              ARRAY<STRING>      OPTIONS (description = "'RH-TokenizedStock', 'Native token', ..."),
  note              STRING             OPTIONS (description = "Free text, ours. Anything a future reader would otherwise have to rediscover"),
  vol_usd           NUMERIC            OPTIONS (description = "Cumulative all-time USD volume, refreshed in place. A scalar, not a history: this is what earned the token a place. Per-hour volume lives in the price feed"),
  _refreshed_at     TIMESTAMP          OPTIONS (description = "When this row's metadata and vol_usd were last written")
)
CLUSTER BY token_address
OPTIONS (
  description = "Tokens the hourly price feed is allowed to price, across every protocol on Robinhood Chain. Dimension table: unpartitioned, clustered on token_address. ETH and WETH are deliberately separate assets. Built by sync/token_mapping.py; SQL in chain/ at github.com/arabianhorses/decentralizedanalysis.com."
);
