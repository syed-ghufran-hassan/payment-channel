
import { Clarinet, Tx, Chain, Account, types } from 'https://deno.land/x/clarinet@v0.14.0/index.ts';
import { assertEquals } from 'https://deno.land/std@0.90.0/testing/asserts.ts';

Clarinet.test({
    name: "Ensure that <...>",
    async fn(chain: Chain, accounts: Map<string, Account>) {
        let block = chain.mineBlock([
            /* 
             * Add transactions with: 
             * Tx.contractCall(...)
            */
        ]);
        assertEquals(block.receipts.length, 0);
        assertEquals(block.height, 2);

        block = chain.mineBlock([
            /* 
             * Add transactions with: 
             * Tx.contractCall(...)
            */
        ]);
        assertEquals(block.receipts.length, 0);
        assertEquals(block.height, 3);
    },
});

Clarinet.test({
  name: "Reject unilateral close replay with stale nonce",
  async fn(chain: Chain, accounts: Map<string, Account>) {
    const alice = accounts.get("wallet_1")!;
    const bob = accounts.get("wallet_2")!;

    const channelId = new Uint8Array(32).fill(1);

    let block = chain.mineBlock([
      Tx.contractCall(
        "payment-channel",
        "create-channel",
        [
          types.buff(channelId),
          types.principal(bob.address),
          types.uint(1_000),
        ],
        alice.address
      ),
    ]);
    block.receipts[0].result.expectOk();

    block = chain.mineBlock([
      Tx.contractCall(
        "payment-channel",
        "initiate-unilateral-close",
        [
          types.buff(channelId),
          types.principal(alice.address),
          types.principal(bob.address),
          types.uint(600),
          types.uint(400),
          types.uint(1),
          types.buff(new Uint8Array(65)),
        ],
        alice.address
      ),
    ]);
    block.receipts[0].result.expectOk();

    block = chain.mineBlock([
      Tx.contractCall(
        "payment-channel",
        "initiate-unilateral-close",
        [
          types.buff(channelId),
          types.principal(alice.address),
          types.principal(bob.address),
          types.uint(500),
          types.uint(500),
          types.uint(1), // stale nonce
          types.buff(new Uint8Array(65)),
        ],
        alice.address
      ),
    ]);

    assertEquals(block.receipts.length, 1);
    block.receipts[0].result.expectErr().expectUint(107); // ERR-INVALID-INPUT
  },
});

/* -----------------------------------------------------
 * Test 2: Either participant can initiate unilateral close
 * ----------------------------------------------------- */
Clarinet.test({
  name: "Allow either participant to initiate unilateral close",
  async fn(chain: Chain, accounts: Map<string, Account>) {
    const alice = accounts.get("wallet_1")!;
    const bob = accounts.get("wallet_2")!;

    const channelId = new Uint8Array(32).fill(2);

    let block = chain.mineBlock([
      Tx.contractCall(
        "payment-channel",
        "create-channel",
        [
          types.buff(channelId),
          types.principal(bob.address),
          types.uint(1_000),
        ],
        alice.address
      ),
    ]);
    block.receipts[0].result.expectOk();

    block = chain.mineBlock([
      Tx.contractCall(
        "payment-channel",
        "initiate-unilateral-close",
        [
          types.buff(channelId),
          types.principal(alice.address),
          types.principal(bob.address),
          types.uint(700),
          types.uint(300),
          types.uint(1),
          types.buff(new Uint8Array(65)),
        ],
        bob.address // Bob initiates
      ),
    ]);

    assertEquals(block.receipts.length, 1);
    block.receipts[0].result.expectOk();
  },
});

/* -----------------------------------------------------
 * Test 3: Dispute deadline cannot be reset (griefing protection)
 * ----------------------------------------------------- */
Clarinet.test({
  name: "Prevent dispute deadline reset after unilateral close",
  async fn(chain: Chain, accounts: Map<string, Account>) {
    const alice = accounts.get("wallet_1")!;
    const bob = accounts.get("wallet_2")!;

    const channelId = new Uint8Array(32).fill(3);

    let block = chain.mineBlock([
      Tx.contractCall(
        "payment-channel",
        "create-channel",
        [
          types.buff(channelId),
          types.principal(bob.address),
          types.uint(1_000),
        ],
        alice.address
      ),
    ]);
    block.receipts[0].result.expectOk();

    block = chain.mineBlock([
      Tx.contractCall(
        "payment-channel",
        "initiate-unilateral-close",
        [
          types.buff(channelId),
          types.principal(alice.address),
          types.principal(bob.address),
          types.uint(600),
          types.uint(400),
          types.uint(1),
          types.buff(new Uint8Array(65)),
        ],
        alice.address
      ),
    ]);
    block.receipts[0].result.expectOk();

    block = chain.mineBlock([
      Tx.contractCall(
        "payment-channel",
        "initiate-unilateral-close",
        [
          types.buff(channelId),
          types.principal(alice.address),
          types.principal(bob.address),
          types.uint(500),
          types.uint(500),
          types.uint(2), // higher nonce, but deadline already set
          types.buff(new Uint8Array(65)),
        ],
        alice.address
      ),
    ]);

    assertEquals(block.receipts.length, 1);
    block.receipts[0].result.expectErr().expectUint(106); // ERR-DISPUTE-PERIOD
  },
});
