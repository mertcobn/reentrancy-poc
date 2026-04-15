# Reentrancy Attack: Proof of Concept & Mitigation Analysis

A Foundry-based demonstration of a classic reentrancy vulnerability on a vulnerable ETH vault, along with two independent mitigations tested in isolation.

## Vulnerability

The withdraw function in the Vault contract violates the Checks-Effects-Interactions pattern. The user's balance is updated to zero after the ETH transfer is performed, not before. This gap allows a malicious contract to re-enter withdraw from inside its own receive or fallback function, exploiting the fact that the balance state has not yet been zeroed. By looping through this pattern, an attacker can drain the entire ETH balance held by the vault.

## Attack Flow

The attack unfolds in seven steps:

1. **Setup.** Honest users (alice, bob, charlie) each deposit 1 ETH into the vault. The attacker also deposits 1 ETH through their malicious contract — this initial deposit is required to pass the require(bal > 0, "no balance") check inside withdraw. The vault now holds 4 ETH in total.

2. **Trigger.** The attacker calls withdraw() on the vault from inside their own Attacker contract.

3. **First transfer.** The vault passes the require check, then executes msg.sender.call{value: bal}(""), sending 1 ETH back to the Attacker contract. Crucially, balances[attacker] has not yet been zeroed at this point.

4. **Callback hijack.** Because the transfer is performed via call with empty calldata, the Attacker contract's receive() function is automatically triggered (or fallback() if receive is not defined).

5. **Reentry loop.** Inside receive(), the attacker checks whether the vault still holds ETH via vault.getBalance() > 0. If true, it calls vault.withdraw() again. Because balances[attacker] was never updated, the new withdraw call passes the require check and sends another 1 ETH. This pattern recurses.

6. **Drain.** The cycle repeats: 1 ETH is withdrawn, receive() re-enters, another 1 ETH is withdrawn, and so on. After 4 iterations, the vault's balance reaches 0. The next getBalance() call returns 0, the if condition fails, and the recursion stops.

7. **Stack unwinding.** As each nested withdraw call returns, the line balances[msg.sender] = 0 finally executes — once per nested call, four times in total. All four writes are no-ops on the same already-stale slot. The attacker contract now holds the full 4 ETH; the vault holds nothing.

## Mitigations

### 1. Checks-Effects-Interactions (CEI)

Implemented in VaultFixedCEI.sol. The fix is a single-line reorder: balances[msg.sender] = 0 is moved before the external call, restoring the canonical Checks-Effects-Interactions ordering.

The reason this works: when the attacker's receive() re-enters withdraw, the second call reads balances[attacker] and finds it already zeroed.

The require(bal > 0, "no balance") check then reverts the inner call, which propagates upward and reverts the entire transaction.

Gas cost: zero. The fix introduces no new opcodes; only the order of existing operations is changed.


### 2. OpenZeppelin ReentrancyGuard

Implemented in VaultFixedGuard.sol. The contract inherits from OpenZeppelin's ReentrancyGuardTransient and applies the nonReentrant modifier to the withdraw function.

```solidity
import "openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";

contract VaultFixedGuard is ReentrancyGuardTransient {
    function withdraw() external nonReentrant { ... }
}
```

The nonReentrant modifier maintains a _status flag that acts as a lock. On entry, it checks whether the contract is already inside a guarded call; if so, it reverts. Otherwise it sets the flag, executes the function body, and clears the flag on exit. When the attacker's receive() attempts to re-enter withdraw, the modifier sees the flag still set from the outer call and reverts immediately — before any balance check or transfer logic is reached.
Gas cost: ~175 gas per call, observed in test traces. The overhead comes from one read and two writes to the _status slot. Note that ReentrancyGuardTransient uses EIP-1153 transient storage (TSTORE/TLOAD), which is significantly cheaper than the classic storage-based ReentrancyGuard (~2,300 gas overhead). The modern transient variant should be preferred on chains that support it.

### Comparison

| Approach | Extra Gas | Applicability | Trade-off |
|---|---|---|---|
| CEI | 0 | Simple flows, single state update | Requires discipline; easy to break as code evolves |
| nonReentrant | ~175 | Complex flows, cross-function protection | Mechanical guarantee; small but recurring cost |

**Production recommendation:** use both. CEI wherever possible (free), `nonReentrant` on all state-changing functions (defense in depth).

## Variants of Reentrancy

- **Single-function reentrancy** — The attacker re-enters the same function during its external call window, exploiting the fact that state has not yet been updated. This is the classic case demonstrated in this PoC.

- **Cross-function reentrancy** — The attacker enters one function and, during its external call window, calls a different function in the same contract that reads or writes the same shared state. The second function operates on stale data, allowing exploits such as double-spending balances. A nonReentrant modifier protects only the function it's applied to; all functions sharing the same state must be guarded together.

- **Read-only / cross-contract reentrancy** — Two contracts are involved. Contract B relies on a view function from Contract A to make decisions (pricing, collateral valuation, etc.). The attacker triggers a state-mutating function in Contract A, and during its external call window, Contract A's internal state is temporarily inconsistent. The attacker then calls Contract B, which queries Contract A's view function and receives a stale, incorrect value — leading to mispriced trades or oversized loans. Contract A itself is never directly exploited; the damage occurs in the consuming protocol. The Curve / Conic Finance incidents (2022–2023) are the canonical examples.

## Reentrancy Audit Checklist

When reviewing a function for reentrancy risk, I work through the following checklist:

1. **Identify all external calls.** Scan the function for `.call`, `.transfer`, `.send`, `delegatecall`, and any cross-contract function invocations (token transfers, oracle queries, callbacks). These are the reentrancy entry points.
2. **Classify each external call by destination.** Is it a known immutable contract (low risk), a user-controlled address (high risk), or a token contract (depends on token type)?
3. **Check the token type.** Standard ERC20s have no transfer hooks. ERC777, ERC721 safeTransfer, and ERC1155 trigger callbacks on the recipient — massive reentrancy surface. If the protocol allows arbitrary tokens, assume the worst.
4. **Verify CEI ordering.** Before each external call, confirm that all relevant state updates (balance reductions, counter increments, flag sets) have already been applied.
5. **Check for cross-function reentrancy.** List every function that reads or writes the same state. Could an attacker, during the external call window, enter another function and exploit the stale state?
6. **Check for read-only / cross-contract reentrancy.** Could an external contract read this contract's view functions during a moment when the state is temporarily inconsistent, and act on the wrong value?
7. **Verify mitigations.** Is `nonReentrant` applied? To all state-changing functions, or only some? Is CEI also followed? Production-grade contracts use both.

## Tests

```bash
forge test -vvv
```

- `test_Reentrancy_OriginalVault_Drained` — Executes the attack against the unpatched Vault and asserts that the vault's balance reaches 0 while the attacker contract holds 4 ETH. Confirms the vulnerability is real and exploitable.

- `test_Reentrancy_CEIFix_Reverts` — Executes the same attack against VaultFixedCEI and expects a revert. Confirms that reordering state updates before the external call is sufficient to block the exploit.

- `test_Reentrancy_GuardFix_Reverts` — Executes the same attack against VaultFixedGuard and expects a revert (with ReentrancyGuardReentrantCall()). Confirms that the modifier-based lock blocks the exploit independently of CEI ordering.

## Historical Context

This vulnerability class has caused some of the largest losses in DeFi history:

- **The DAO (June 2016)** — ~$60M drained via classic single-function reentrancy. The incident led to the contentious hard fork that split Ethereum and Ethereum Classic.
- **Lendf.Me (April 2020)** — ~$25M drained via ERC777 transfer hooks (imBTC). The attacker re-entered supply() repeatedly, inflating their collateral balance.
- **Cream Finance (August 2021)** — ~$18.8M drained via the AMP token's ERC777-style hooks, exploiting the same transfer-callback pattern.
- **Conic Finance (July 2023)** — ~$3.6M drained via read-only reentrancy on a Curve pool's get_virtual_price().

Despite being one of the oldest documented Solidity vulnerabilities, reentrancy continues to surface because each new token standard, callback pattern, and cross-protocol integration introduces fresh surface area.

## References

- [Solidity Docs: Checks-Effects-Interactions](https://docs.soliditylang.org/en/latest/security-considerations.html#use-the-checks-effects-interactions-pattern)
- [OpenZeppelin ReentrancyGuard](https://docs.openzeppelin.com/contracts/5.x/api/utils#reentrancyguard)
- [SWC-107: Reentrancy](https://swcregistry.io/docs/SWC-107)

---

*Built as part of a structured audit training curriculum.*