// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

// forge test --match-path test/FreeCoin.mainnet.t.sol -vvv --fork-url https://bsc-dataseed.bnbchain.org

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {FlapBSCFixture} from "./FlapBSCFixture.sol";
import {VanityHelper} from "./lib/VanityHelper.sol";

import {FreeCoinVault, FreeCoinVaultFactory} from "../src/FreeCoin.sol";
import {IVaultPortalTypes} from "../src/flap/IVaultPortal.sol";
import {IPortalTypes} from "../src/flap/IPortal.sol";
import {IFlapTaxTokenV3} from "../src/flap/IFlapTaxTokenV3.sol";
import {ITaxProcessor} from "../src/flap/ITaxProcessor.sol";

// ============================================================
//  FreeCoin Mainnet Fork Tests
// ============================================================

/// @title FreeCoinMainnetTest
/// @notice Mainnet-fork integration tests for FreeCoinVault + FreeCoinVaultFactory.
///
/// @dev ── WHAT THESE TESTS VERIFY ──────────────────────────────────────────────
///
/// 1. Deploy FreeCoinVaultFactory.
/// 2. Launch a V3 tax token through VaultPortal using the factory — the vault is
///    automatically created and set as the tax revenue recipient (marketAddress).
/// 3. Buy tokens on the bonding curve → triggers `processBondingCurveTax()` inside Portal.
///    The TaxProcessor accumulates BNB in `marketQuoteBalance`.
/// 4. Call `dispatch()` on the TaxProcessor → BNB flows from TaxProcessor into the vault.
/// 5. Graduate token to DEX by buying enough to cross the FOUR_FIFTHS threshold.
/// 6. Sell tokens on DEX → sell tax applied, more BNB flows into TaxProcessor.
/// 7. Dispatch again → vault receives post-DEX tax revenue.
/// 8. Users claim from the vault — verify cooldown, single-claim enforcement, and payout cap.
///
/// ── RUN ───────────────────────────────────────────────────────────────────────
///
///   forge test --match-path test/FreeCoin.mainnet.t.sol -vvv \
///       --fork-url https://bsc-dataseed.bnbchain.org
///
///   Or set BSC_RPC_URL in your environment and run without --fork-url:
///
///   BSC_RPC_URL=https://bsc-dataseed.bnbchain.org forge test \
///       --match-path test/FreeCoin.mainnet.t.sol -vvv
///
contract FreeCoinMainnetTest is FlapBSCFixture {
    // ──────────────────────────────────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────────────────────────────────

    FreeCoinVaultFactory public factory;
    FreeCoinVault public vault;
    address public token;
    address public taxProcessorAddr;

    // Use 0x7777...7777-prefixed addresses to avoid collisions with real on-chain
    // accounts (system contracts, precompiles, or funded wallets) on BSC mainnet fork.
    // The 0x7777 pattern is not a known precompile range and has no corresponding private key.
    address public user1   = address(0x7777777777777777777777777777777777771001);
    address public user2   = address(0x7777777777777777777777777777777777771002);
    address public user3   = address(0x7777777777777777777777777777777777771003);
    address public creator = address(0x7777777777777777777777777777777777771004);

    // FreeCoinVault parameters
    uint256 constant MAX_REWARD = 0.01 ether; // 0.01 BNB per claim
    uint256 constant COOLDOWN = 1 hours; // 1 hour between claims

    // ──────────────────────────────────────────────────────────────────────────
    //  Set Up
    // ──────────────────────────────────────────────────────────────────────────

    function setUp() public {
        // 1. Fork BSC mainnet (pins to latest block or BSC_RPC_URL env var)
        _forkBSCMainnet();

        // 2. Fund test accounts
        vm.deal(creator, 100 ether);
        vm.deal(user1, 20 ether);
        vm.deal(user2, 20 ether);
        vm.deal(user3, 20 ether);

        // 3. Deploy FreeCoinVaultFactory
        //    The factory reads its VaultPortal address from block.chainid at call time,
        //    so it automatically targets the live VaultPortal on BSC mainnet.
        vm.startPrank(creator);
        factory = new FreeCoinVaultFactory();
        vm.label(address(factory), "FreeCoinVaultFactory");
        vm.stopPrank();

        // 4. Find a vanity salt whose predicted token address ends in 0x7777.
        //    TOKEN_IMPL_TAXED_V3 + PORTAL determine the clone address space.
        bytes32 salt = _findVanitySalt(VanityType.VANITY_7777, TOKEN_IMPL_TAXED_V3, PORTAL);

        // 5. Encode vaultData: FreeCoinVaultFactory expects (uint256 maxReward, uint256 cooldown)
        bytes memory vaultData = abi.encode(MAX_REWARD, COOLDOWN);

        // 6. Build scaffold params and customise
        IVaultPortalTypes.NewTokenV6WithVaultParams memory params =
            _buildV3TaxTokenParams("Free Coin", "FREE", salt, address(factory), vaultData);

        // Customise: 5% symmetric tax, all market revenue → vault
        params.buyTaxRate = 500; // 5%
        params.sellTaxRate = 500; // 5%
        params.mktBps = 10000; // 100% of tax remainder → vault (after protocol fee)
        params.deflationBps = 0;
        params.dividendBps = 0;
        params.lpBps = 0;

        // 7. Launch the token + vault in a single transaction through VaultPortal
        //    Gas is capped at MAX_OP_GAS to ensure the launch fits within a single BSC block.
        vm.startPrank(creator);
        token = vaultPortal.newTokenV6WithVault{value: params.quoteAmt, gas: MAX_OP_GAS}(params);
        vm.stopPrank();

        // 8. Resolve vault and taxProcessor addresses
        IVaultPortalTypes.VaultInfo memory info = vaultPortal.getVault(token);
        vault = FreeCoinVault(payable(info.vault));
        taxProcessorAddr = IFlapTaxTokenV3(token).taxProcessor();

        vm.label(token, "FreeCoin:Token");
        vm.label(address(vault), "FreeCoin:Vault");
        vm.label(taxProcessorAddr, "FreeCoin:TaxProcessor");

        console2.log("Token:        %s", token);
        console2.log("Vault:        %s", address(vault));
        console2.log("TaxProcessor: %s", taxProcessorAddr);
        console2.log("MaxReward:    %s wei", MAX_REWARD);
        console2.log("Cooldown:     %s seconds", COOLDOWN);
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Test 1: Token address ends with 0x7777
    // ──────────────────────────────────────────────────────────────────────────

    function test_tokenAddressEndsIn7777() public view {
        bytes20 addrBytes = bytes20(token);
        assertTrue(addrBytes[18] == 0x77 && addrBytes[19] == 0x77, "Token address should end in 0x7777");
        console2.log("[PASS] Token address: %s (ends in 7777)", token);
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Test 2: Vault is configured correctly
    // ──────────────────────────────────────────────────────────────────────────

    function test_vaultConfiguration() public view {
        assertEq(vault.taxToken(), token, "vault.taxToken() should equal the launched token");
        assertEq(vault.maxReward(), MAX_REWARD, "vault.maxReward() mismatch");
        assertEq(vault.cooldown(), COOLDOWN, "vault.cooldown() mismatch");

        // TaxProcessor's marketAddress should point to the vault
        address marketAddr = ITaxProcessor(taxProcessorAddr).marketAddress();
        assertEq(marketAddr, address(vault), "TaxProcessor.marketAddress() should be the vault");

        console2.log("[PASS] Vault configuration verified");
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Test 3: Buy on bonding curve → tax accumulates → dispatch → vault receives BNB
    // ──────────────────────────────────────────────────────────────────────────

    function test_buyOnBCAndDispatch() public {
        uint256 buyAmount = 5 ether;

        uint256 vaultBalanceBefore = address(vault).balance;

        console2.log("=== Buying %s BNB on bonding curve ===", buyAmount / 1 ether);

        vm.startPrank(user1);
        uint256 tokensReceived = _buyOnBC(token, buyAmount);
        vm.stopPrank();
        console2.log("Tokens received: %s", tokensReceived);

        // Dispatch: flush TaxProcessor balances → vault receives BNB
        _dispatchTax(token);
        console2.log("Dispatched tax");

        uint256 vaultBalanceAfter = address(vault).balance;
        console2.log("Vault balance before dispatch: %s wei", vaultBalanceBefore);
        console2.log("Vault balance after dispatch:  %s wei", vaultBalanceAfter);
        assertGt(vaultBalanceAfter, vaultBalanceBefore, "Vault should have received BNB after dispatch");

        console2.log("[PASS] Buy on BC + dispatch: vault received %s wei", vaultBalanceAfter - vaultBalanceBefore);
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Test 4: Graduate to DEX, sell, dispatch post-DEX
    // ──────────────────────────────────────────────────────────────────────────
    //  Test 4: Graduate to DEX, sell, dispatch post-DEX
    // ──────────────────────────────────────────────────────────────────────────

    function test_graduateAndDispatchPostDEX() public {
        // Buy enough to cross the FOUR_FIFTHS graduation threshold (~17 BNB total for standard curve)
        console2.log("=== Graduating token to DEX ===");

        // Buy in two tranches so we can observe BC tax first, then DEX sell tax
        vm.startPrank(user1);
        _buyOnBC(token, 5 ether);
        vm.stopPrank();

        _dispatchTax(token); // flush BC tax

        vm.startPrank(user2);
        _buyOnBC(token, 15 ether); // this should push over the graduation threshold
        vm.stopPrank();

        // Check graduation
        IPortalTypes.TokenStateV8Safe memory state = portal.getTokenV8Safe(token);
        console2.log("Token status after second buy: %s (4=DEX)", state.status);

        if (state.status != 4) {
            // Not yet graduated — buy more
            vm.startPrank(user3);
            _buyOnBC(token, 10 ether);
            vm.stopPrank();
            state = portal.getTokenV8Safe(token);
        }
        assertEq(state.status, 4, "Token should have graduated to DEX (status=4)");
        console2.log("[PASS] Token graduated to DEX");

        // Now sell all user1 tokens on DEX — 5% sell tax applied
        uint256 user1Balance = IERC20(token).balanceOf(user1);
        console2.log("user1 token balance: %s", user1Balance);

        uint256 vaultBefore = address(vault).balance;

        // Transfer 400K tokens directly to the token contract to ensure the tax
        // liquidation threshold is met during the DEX sell, guaranteeing that
        // the swap-and-distribute logic fires and BNB accumulates in TaxProcessor.
        // NOTE: _sell() internally calls approve() then swapExactInput(), so both
        // calls must be covered by startPrank/stopPrank — a bare vm.prank() would
        // only cover the first external call (approve) and leave the swap unpranked.
        vm.startPrank(user1);
        IERC20(token).transfer(token, 400_000 * 1e18);
        uint256 bnbReceived = _sell(token, user1Balance - 400_000 * 1e18);
        vm.stopPrank();
        console2.log("user1 sold tokens, received %s BNB", bnbReceived);

        // Dispatch post-DEX tax to vault
        _dispatchTax(token);
        uint256 vaultAfter = address(vault).balance;
        assertGt(vaultAfter, vaultBefore, "Vault should receive BNB from post-DEX dispatch");

        console2.log("[PASS] DEX sell + dispatch: vault received %s wei", vaultAfter - vaultBefore);
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Test 5: Claim from vault
    // ──────────────────────────────────────────────────────────────────────────

    function test_claimFromVault() public {
        // First, fund the vault by buying and dispatching tax
        vm.startPrank(user1);
        _buyOnBC(token, 5 ether);
        vm.stopPrank();
        _dispatchTax(token);

        uint256 vaultBalance = address(vault).balance;
        require(vaultBalance > 0, "Vault must have BNB before testing claim");
        console2.log("Vault balance before claim: %s wei", vaultBalance);

        // user2 claims
        uint256 user2BalanceBefore = user2.balance;
        vm.startPrank(user2);
        vault.claim{gas: MAX_OP_GAS}();
        vm.stopPrank();
        uint256 user2BalanceAfter = user2.balance;

        uint256 reward = user2BalanceAfter - user2BalanceBefore;
        console2.log("user2 claimed: %s wei", reward);

        // Reward should be min(vaultBalance, maxReward)
        uint256 expectedReward = vaultBalance < MAX_REWARD ? vaultBalance : MAX_REWARD;
        assertEq(reward, expectedReward, "Reward should be min(balance, maxReward)");
        assertTrue(vault.hasClaimed(user2), "user2 should be marked as claimed");
        assertEq(vault.lastClaimer(), user2, "lastClaimer should be user2");

        console2.log("[PASS] Claim succeeded: user2 received %s wei", reward);
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Test 6: Second claim by same address is rejected
    // ──────────────────────────────────────────────────────────────────────────

    function test_cannotClaimTwice() public {
        // Fund the vault
        vm.startPrank(user1);
        _buyOnBC(token, 5 ether);
        vm.stopPrank();
        _dispatchTax(token);
        require(address(vault).balance > 0, "Vault must have BNB");

        // First claim
        vm.startPrank(user2);
        vault.claim{gas: MAX_OP_GAS}();
        vm.stopPrank();

        // Second claim — should revert
        vm.expectRevert();
        vm.startPrank(user2);
        vault.claim{gas: MAX_OP_GAS}();
        vm.stopPrank();

        console2.log("[PASS] Double-claim correctly rejected");
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Test 7: Cooldown enforced between different users
    // ──────────────────────────────────────────────────────────────────────────

    function test_cooldownEnforcedBetweenUsers() public {
        // Fund the vault with enough for multiple claims
        vm.startPrank(user1);
        _buyOnBC(token, 10 ether);
        vm.stopPrank();
        _dispatchTax(token);

        // More BNB via more buys and dispatches
        vm.startPrank(user2);
        _buyOnBC(token, 5 ether);
        vm.stopPrank();
        _dispatchTax(token);
        require(address(vault).balance > MAX_REWARD * 2, "Need enough BNB for two claims");

        // user1 claims
        vm.startPrank(user1);
        vault.claim{gas: MAX_OP_GAS}();
        vm.stopPrank();
        console2.log("user1 claimed at timestamp %s", block.timestamp);

        // user2 tries to claim immediately — should fail due to cooldown
        vm.expectRevert();
        vm.startPrank(user2);
        vault.claim{gas: MAX_OP_GAS}();
        vm.stopPrank();
        console2.log("[PASS] user2 correctly blocked by global cooldown");

        // Advance time past cooldown
        vm.warp(block.timestamp + COOLDOWN + 1);

        // user2 can now claim
        vm.startPrank(user2);
        vault.claim{gas: MAX_OP_GAS}();
        vm.stopPrank();
        console2.log("[PASS] user2 successfully claimed after cooldown elapsed");
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Test 8: getNextReward() returns correct value
    // ──────────────────────────────────────────────────────────────────────────

    function test_getNextReward() public {
        // Fund the vault below maxReward
        vm.deal(address(vault), MAX_REWARD / 2);
        uint256 expected = MAX_REWARD / 2; // balance < maxReward → returns balance
        assertEq(vault.getNextReward(), expected, "getNextReward() should return balance when balance < maxReward");

        // Fund the vault above maxReward
        vm.deal(address(vault), MAX_REWARD * 3);
        assertEq(vault.getNextReward(), MAX_REWARD, "getNextReward() should return maxReward when balance >= maxReward");

        console2.log("[PASS] getNextReward() returns correct capped value");
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Test 9: Multiple buys and dispatches accumulate in vault
    // ──────────────────────────────────────────────────────────────────────────

    function test_multipleDispatchesAccumulate() public {
        uint256 vaultBalanceBefore = address(vault).balance;

        // Three separate buy + dispatch cycles
        for (uint256 i = 0; i < 3; i++) {
            address buyer = i == 0 ? user1 : (i == 1 ? user2 : user3);
            vm.startPrank(buyer);
            _buyOnBC(token, 3 ether);
            vm.stopPrank();
            _dispatchTax(token);
            console2.log("Cycle %s: vault balance = %s wei", i + 1, address(vault).balance);
        }

        uint256 vaultBalanceAfter = address(vault).balance;
        assertGt(vaultBalanceAfter, vaultBalanceBefore, "Vault should accumulate BNB across multiple dispatches");

        console2.log("[PASS] Multiple dispatches accumulated: total vault balance = %s wei", vaultBalanceAfter);
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Test 10: VaultPortal.getVaultInfo() returns correct vault details
    // ──────────────────────────────────────────────────────────────────────────

    function test_vaultPortalGetVaultInfo() public view {
        IVaultPortalTypes.VaultInfo memory info = vaultPortal.getVault(token);

        assertEq(info.vault, address(vault), "getVault().vault mismatch");
        assertEq(info.vaultFactory, address(factory), "getVault().vaultFactory mismatch");

        console2.log("[PASS] VaultPortal.getVault() returns correct data");
        console2.log("  vault:        %s", info.vault);
        console2.log("  vaultFactory: %s", info.vaultFactory);
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Receive BNB (needed when calling swapExactInput on DEX for native output)
    // ──────────────────────────────────────────────────────────────────────────

    receive() external payable {}
}
