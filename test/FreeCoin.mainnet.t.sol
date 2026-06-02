// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

// forge test --match-path test/FreeCoin.mainnet.t.sol -vvv --fork-url https://bsc-dataseed.bnbchain.org

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {FlapBSCFixture} from "./FlapBSCFixture.sol";
import {VanityHelper} from "./lib/VanityHelper.sol";

import {FreeCoinVault, FreeCoinVaultFactory} from "src/FreeCoin.sol";
import {IVaultPortalTypes} from "src/flap/IVaultPortal.sol";
import {IPortalTypes} from "src/flap/IPortal.sol";
import {IFlapTaxTokenV3} from "src/flap/IFlapTaxTokenV3.sol";
import {ITaxProcessor} from "src/flap/ITaxProcessor.sol";
import {VaultUISchema, VaultDataSchema, FactoryPolicy} from "src/flap/IVaultSchemasV1.sol";
import {VaultFactoryBaseV2} from "src/flap/VaultFactoryBaseV2.sol";
import {IVaultFactoryValidationV2} from "src/flap/IVaultFactory.sol";

contract RejectNativeReceiverV1 {
    receive() external payable {
        revert("reject-native");
    }
}

contract RejectingClaimerV1 {
    receive() external payable {
        revert("reject-claim");
    }

    function claim(address vault) external {
        FreeCoinVault(payable(vault)).claim();
    }
}

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
    address public user1 = address(0x7777777777777777777777777777777777771001);
    address public user2 = address(0x7777777777777777777777777777777777771002);
    address public user3 = address(0x7777777777777777777777777777777777771003);
    address public creator = address(0x7777777777777777777777777777777777771004);
    address public unitForwardTo = address(0x7777777777777777777777777777777777773001);

    // FreeCoinVault parameters
    uint256 constant MAX_REWARD = 0.01 ether; // 0.01 BNB per claim
    uint256 constant COOLDOWN = 1 hours; // 1 hour between claims

    uint256 constant UNIT_MAX_REWARD = 0.25 ether;
    uint256 constant UNIT_COOLDOWN = 30 minutes;

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
        require(IERC20(token).transfer(token, 400_000 * 1e18), "seed transfer failed");
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
    //  Test 9: Getter helpers reflect claim state transitions
    // ──────────────────────────────────────────────────────────────────────────

    function test_claimStateGetters() public {
        (address initialClaimer, uint256 initialReward) = vault.getLastClaimerAndReward();
        assertEq(vault.getNextClaimTime(), 0, "Initial next claim time should be zero");
        assertEq(initialClaimer, address(0), "Initial last claimer should be zero");
        assertEq(initialReward, 0, "Initial last reward should be zero");

        vm.deal(address(vault), MAX_REWARD * 2);

        vm.startPrank(user2);
        vault.claim{gas: MAX_OP_GAS}();
        vm.stopPrank();

        assertEq(vault.getNextClaimTime(), block.timestamp + COOLDOWN, "Next claim time should advance by cooldown");

        (address claimer, uint256 reward) = vault.getLastClaimerAndReward();
        assertEq(claimer, user2, "Last claimer getter mismatch");
        assertEq(reward, MAX_REWARD, "Last reward getter mismatch");
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Test 10: Guardian can enable auto-forward mode
    // ──────────────────────────────────────────────────────────────────────────

    function test_setAutoForwardAndForwarding() public {
        address forwardTo = address(0x7777777777777777777777777777777777772001);

        vm.prank(FLAP_GUARDIAN);
        vault.setAutoForward(true, forwardTo);

        assertTrue(vault.autoForwardEnabled(), "Auto-forward should be enabled");
        assertEq(vault.forwardAddress(), forwardTo, "Forward address mismatch");

        vm.deal(user3, 1 ether);
        uint256 receiverBefore = forwardTo.balance;

        vm.prank(user3);
        (bool ok,) = payable(address(vault)).call{value: 0.4 ether}("");
        assertTrue(ok, "Forwarding transfer should succeed");

        assertEq(address(vault).balance, 0, "Vault should not retain forwarded BNB");
        assertEq(forwardTo.balance - receiverBefore, 0.4 ether, "Forward recipient should receive BNB");
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Test 11: Guardian can emergency withdraw native BNB from inherited hook
    // ──────────────────────────────────────────────────────────────────────────

    function test_emergencyWithdrawNative() public {
        address recipient = address(0x7777777777777777777777777777777777772002);
        uint256 amount = 0.75 ether;

        vm.deal(address(vault), amount);
        uint256 recipientBefore = recipient.balance;

        vm.prank(FLAP_GUARDIAN);
        vault.emergencyWithdrawNative(recipient);

        assertEq(address(vault).balance, 0, "Vault native balance should be drained");
        assertEq(recipient.balance - recipientBefore, amount, "Recipient should receive full native balance");
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Test 12: Guardian can emergency withdraw ERC-20 from inherited hook
    // ──────────────────────────────────────────────────────────────────────────

    function test_emergencyWithdrawToken() public {
        address recipient = address(0x7777777777777777777777777777777777772003);

        vm.startPrank(user1);
        uint256 tokensReceived = _buyOnBC(token, 5 ether);
        IERC20(token).transfer(address(vault), tokensReceived / 2);
        vm.stopPrank();

        uint256 vaultTokenBalance = IERC20(token).balanceOf(address(vault));
        require(vaultTokenBalance > 0, "Vault must hold ERC20 tokens before emergency withdraw");

        vm.prank(FLAP_GUARDIAN);
        vault.emergencyWithdrawToken(token, recipient);

        assertEq(IERC20(token).balanceOf(address(vault)), 0, "Vault ERC20 balance should be drained");
        assertEq(IERC20(token).balanceOf(recipient), vaultTokenBalance, "Recipient should receive full ERC20 balance");
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Test 13: vaultUISchema() describes the expected UI surface
    // ──────────────────────────────────────────────────────────────────────────

    function test_vaultUISchema() public view {
        VaultUISchema memory schema = vault.vaultUISchema();

        assertEq(schema.vaultType, "FreeCoinVault", "vaultUISchema.vaultType mismatch");
        assertEq(schema.methods.length, 4, "vaultUISchema method count mismatch");

        assertEq(schema.methods[0].name, "getNextReward", "Method[0] name mismatch");
        assertEq(schema.methods[0].outputs.length, 1, "Method[0] outputs length mismatch");
        assertEq(schema.methods[0].outputs[0].name, "reward", "Method[0] output name mismatch");

        assertEq(schema.methods[1].name, "getNextClaimTime", "Method[1] name mismatch");
        assertEq(schema.methods[1].outputs.length, 1, "Method[1] outputs length mismatch");
        assertEq(schema.methods[1].outputs[0].fieldType, "time", "Method[1] output type mismatch");

        assertEq(schema.methods[2].name, "getLastClaimerAndReward", "Method[2] name mismatch");
        assertEq(schema.methods[2].outputs.length, 2, "Method[2] outputs length mismatch");
        assertEq(schema.methods[2].outputs[0].name, "claimer", "Method[2] first output mismatch");
        assertEq(schema.methods[2].outputs[1].name, "reward", "Method[2] second output mismatch");

        assertEq(schema.methods[3].name, "claim", "Method[3] name mismatch");
        assertTrue(schema.methods[3].isWriteMethod, "claim should be marked write-method");
        assertEq(schema.methods[3].inputs.length, 0, "claim should not require inputs");
        assertEq(schema.methods[3].approvals.length, 0, "claim should not require approvals");
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Test 14: Multiple buys and dispatches accumulate in vault
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
    //  Test 15: Factory schema helpers return expected metadata
    // ──────────────────────────────────────────────────────────────────────────

    function test_factorySchemaAndQuoteSupport() public view {
        assertTrue(factory.isQuoteTokenSupported(address(0)), "Factory should support native BNB quote token");
        assertTrue(!factory.isQuoteTokenSupported(address(1)), "Factory should reject non-native quote tokens");

        VaultDataSchema memory schema = factory.vaultDataSchema();
        assertEq(schema.fields.length, 2, "vaultDataSchema field count mismatch");
        assertEq(schema.fields[0].name, "maxReward", "vaultDataSchema field[0] name mismatch");
        assertEq(schema.fields[0].fieldType, "uint256", "vaultDataSchema field[0] type mismatch");
        assertEq(schema.fields[0].decimals, 18, "vaultDataSchema field[0] decimals mismatch");
        assertEq(schema.fields[1].name, "cooldown", "vaultDataSchema field[1] name mismatch");
        assertEq(schema.fields[1].fieldType, "uint256", "vaultDataSchema field[1] type mismatch");
        assertEq(schema.fields[1].decimals, 0, "vaultDataSchema field[1] decimals mismatch");
        assertTrue(!schema.isArray, "vaultDataSchema should describe a single tuple");
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Test 16: Legacy V6 validation hook reverts with the inherited default
    // ──────────────────────────────────────────────────────────────────────────

    function test_legacyV6ValidationHookReverts() public {
        IVaultPortalTypes.NewTokenV6WithVaultParams memory params;

        vm.expectRevert(VaultFactoryBaseV2.LegacyV6ValidationHookNotImplemented.selector);
        factory.onBeforeNewTokenV6WithVault(params);
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Test 17: tokenCreationPolicies() stays empty on the inherited default
    // ──────────────────────────────────────────────────────────────────────────

    function test_tokenCreationPoliciesIsEmpty() public view {
        assertEq(
            factory.tokenCreationPolicies().length, 0, "FreeCoin factory should inherit empty tokenCreationPolicies()"
        );
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Test 18: VaultPortal.getVaultInfo() returns correct vault details
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
    //  Unit coverage tests for src/FreeCoin.sol (merged into this contract)
    // ──────────────────────────────────────────────────────────────────────────

    function _deployStandaloneUnitVault() internal returns (FreeCoinVaultFactory unitFactory, FreeCoinVault unitVault) {
        unitFactory = new FreeCoinVaultFactory();

        vm.prank(VAULT_PORTAL);
        address vaultAddr = unitFactory.newVault(
            address(0xBEEF), address(0), address(this), abi.encode(UNIT_MAX_REWARD, UNIT_COOLDOWN)
        );
        unitVault = FreeCoinVault(payable(vaultAddr));
    }

    function test_unit_factoryDeploysConfiguredVault() public {
        (FreeCoinVaultFactory unitFactory, FreeCoinVault unitVault) = _deployStandaloneUnitVault();

        assertEq(address(unitFactory) != address(0), true, "factory should deploy");
        assertEq(unitVault.taxToken(), address(0xBEEF), "taxToken mismatch");
        assertEq(unitVault.maxReward(), UNIT_MAX_REWARD, "maxReward mismatch");
        assertEq(unitVault.cooldown(), UNIT_COOLDOWN, "cooldown mismatch");
        assertEq(unitVault.getNextClaimTime(), 0, "next claim time should start at zero");
    }

    function test_unit_descriptionBeforeAndAfterClaim() public {
        (, FreeCoinVault unitVault) = _deployStandaloneUnitVault();

        assertEq(
            unitVault.description(),
            unicode"FreeCoinVault: No claims yet. Call claim() to receive free BNB! / 还没有人领取，调用 claim() 领取免费 BNB！",
            "initial description mismatch"
        );

        vm.deal(address(unitVault), UNIT_MAX_REWARD);
        vm.prank(user1);
        unitVault.claim();

        assertEq(
            unitVault.description(),
            unicode"FreeCoinVault: Free BNB for everyone! Call claim() to receive your reward. / 人人有份的免费 BNB！调用 claim() 领取奖励。",
            "post-claim description mismatch"
        );
    }

    function test_unit_claimWithZeroBalanceStillUpdatesState() public {
        (, FreeCoinVault unitVault) = _deployStandaloneUnitVault();

        vm.prank(user1);
        unitVault.claim();

        assertTrue(unitVault.hasClaimed(user1), "zero-balance claim should still mark address claimed");
        assertEq(unitVault.lastClaimer(), user1, "lastClaimer mismatch");
        assertEq(unitVault.lastReward(), 0, "lastReward should be zero");
        assertEq(unitVault.getNextClaimTime(), block.timestamp + UNIT_COOLDOWN, "next claim time mismatch");
    }

    function test_unit_claimSuccessCooldownAndDoubleClaimReverts() public {
        (, FreeCoinVault unitVault) = _deployStandaloneUnitVault();
        vm.deal(address(unitVault), 1 ether);

        uint256 userBalanceBefore = user1.balance;

        vm.prank(user1);
        unitVault.claim();

        uint256 reward = user1.balance - userBalanceBefore;
        assertEq(reward, UNIT_MAX_REWARD, "claim reward should be capped by maxReward");
        assertTrue(unitVault.hasClaimed(user1), "user should be marked as claimed");
        assertEq(unitVault.lastClaimer(), user1, "lastClaimer mismatch");
        assertEq(unitVault.lastReward(), UNIT_MAX_REWARD, "lastReward mismatch");
        assertEq(unitVault.getNextClaimTime(), block.timestamp + UNIT_COOLDOWN, "cooldown should advance after claim");

        vm.expectRevert(bytes(unicode"Already claimed / 已经领取过"));
        vm.prank(user1);
        unitVault.claim();

        vm.expectRevert(bytes(unicode"Cooldown not elapsed / 冷却时间未结束"));
        vm.prank(user2);
        unitVault.claim();
    }

    function test_unit_claimRevertsWhenRecipientRejectsNativeTransfer() public {
        (, FreeCoinVault unitVault) = _deployStandaloneUnitVault();
        RejectingClaimerV1 rejectingClaimer = new RejectingClaimerV1();

        vm.deal(address(unitVault), UNIT_MAX_REWARD);

        vm.expectRevert(bytes(unicode"Transfer failed / 转账失败"));
        rejectingClaimer.claim(address(unitVault));

        assertTrue(!unitVault.hasClaimed(address(rejectingClaimer)), "failed claim should roll back claimed flag");
        assertEq(unitVault.lastClaimer(), address(0), "failed claim should not persist lastClaimer");
        assertEq(unitVault.lastReward(), 0, "failed claim should not persist lastReward");
    }

    function test_unit_getterHelpersAndCappedReward() public {
        (, FreeCoinVault unitVault) = _deployStandaloneUnitVault();

        (address initialClaimer, uint256 initialReward) = unitVault.getLastClaimerAndReward();
        assertEq(initialClaimer, address(0), "initial claimer should be zero");
        assertEq(initialReward, 0, "initial reward should be zero");

        vm.deal(address(unitVault), UNIT_MAX_REWARD / 2);
        assertEq(unitVault.getNextReward(), UNIT_MAX_REWARD / 2, "reward should equal balance below cap");

        vm.deal(address(unitVault), UNIT_MAX_REWARD * 2);
        assertEq(unitVault.getNextReward(), UNIT_MAX_REWARD, "reward should be capped at maxReward");
        assertEq(unitVault.getNextClaimTime(), 0, "nextClaimTime should start at zero");
    }

    function test_unit_setAutoForwardRequiresGuardianAndRejectsZeroAddress() public {
        (, FreeCoinVault unitVault) = _deployStandaloneUnitVault();

        vm.expectRevert(bytes(unicode"Only Guardian / 仅 Guardian"));
        vm.prank(user1);
        unitVault.setAutoForward(true, unitForwardTo);

        vm.expectRevert(bytes(unicode"Invalid forward address / 无效转发地址"));
        vm.prank(FLAP_GUARDIAN);
        unitVault.setAutoForward(true, address(0));
    }

    function test_unit_setAutoForwardDisableKeepsFundsInVault() public {
        (, FreeCoinVault unitVault) = _deployStandaloneUnitVault();

        vm.prank(FLAP_GUARDIAN);
        unitVault.setAutoForward(true, unitForwardTo);
        assertTrue(unitVault.autoForwardEnabled(), "auto-forward should be enabled");
        assertEq(unitVault.forwardAddress(), unitForwardTo, "forwardAddress mismatch after enable");

        vm.prank(FLAP_GUARDIAN);
        unitVault.setAutoForward(false, address(0));
        assertTrue(!unitVault.autoForwardEnabled(), "auto-forward should be disabled");
        assertEq(unitVault.forwardAddress(), unitForwardTo, "forwardAddress should remain stored");

        uint256 vaultBalanceBefore = address(unitVault).balance;
        vm.prank(user1);
        (bool ok,) = address(unitVault).call{value: 0.4 ether}("");
        assertTrue(ok, "transfer should succeed when forwarding disabled");
        assertEq(address(unitVault).balance, vaultBalanceBefore + 0.4 ether, "vault should retain funds when disabled");
    }

    function test_unit_receiveAutoForwardSuccessAndFailure() public {
        (, FreeCoinVault unitVault) = _deployStandaloneUnitVault();
        RejectNativeReceiverV1 rejectingReceiver = new RejectNativeReceiverV1();

        vm.prank(FLAP_GUARDIAN);
        unitVault.setAutoForward(true, unitForwardTo);

        uint256 receiverBefore = unitForwardTo.balance;
        vm.prank(user1);
        (bool ok,) = address(unitVault).call{value: 0.3 ether}("");
        assertTrue(ok, "forwarding transfer should succeed");
        assertEq(address(unitVault).balance, 0, "vault should not keep forwarded funds");
        assertEq(unitForwardTo.balance - receiverBefore, 0.3 ether, "forward target should receive BNB");

        vm.prank(FLAP_GUARDIAN);
        unitVault.setAutoForward(true, address(rejectingReceiver));

        vm.prank(user2);
        (bool failedOk,) = address(unitVault).call{value: 0.1 ether}("");
        assertTrue(!failedOk, "forwarding to a rejecting receiver should fail");
    }

    function test_unit_vaultUISchemaMetadata() public {
        (, FreeCoinVault unitVault) = _deployStandaloneUnitVault();
        VaultUISchema memory schema = unitVault.vaultUISchema();

        assertEq(schema.vaultType, "FreeCoinVault", "vaultType mismatch");
        assertEq(schema.methods.length, 4, "method count mismatch");
        assertEq(schema.methods[0].name, "getNextReward", "method 0 mismatch");
        assertEq(schema.methods[0].outputs[0].name, "reward", "method 0 output mismatch");
        assertEq(schema.methods[1].name, "getNextClaimTime", "method 1 mismatch");
        assertEq(schema.methods[1].outputs[0].fieldType, "time", "method 1 output type mismatch");
        assertEq(schema.methods[2].name, "getLastClaimerAndReward", "method 2 mismatch");
        assertEq(schema.methods[2].outputs.length, 2, "method 2 outputs length mismatch");
        assertEq(schema.methods[3].name, "claim", "method 3 mismatch");
        assertTrue(schema.methods[3].isWriteMethod, "claim should be write method");
        assertEq(schema.methods[3].approvals.length, 0, "claim should not need approvals");
    }

    function test_unit_factoryRejectsNonVaultPortalCaller() public {
        FreeCoinVaultFactory unitFactory = new FreeCoinVaultFactory();

        vm.expectRevert(bytes(unicode"Only VaultPortal / 仅限 VaultPortal 调用"));
        unitFactory.newVault(address(0xBEEF), address(0), address(this), abi.encode(UNIT_MAX_REWARD, UNIT_COOLDOWN));
    }

    function test_unit_factoryMetadataAndValidationHelpers() public {
        FreeCoinVaultFactory unitFactory = new FreeCoinVaultFactory();

        assertTrue(unitFactory.isQuoteTokenSupported(address(0)), "native quote token should be supported");
        assertTrue(!unitFactory.isQuoteTokenSupported(address(1)), "ERC20 quote token should be rejected");
        assertEq(unitFactory.factorySpecVersion(), "v2.2", "factory spec version mismatch");

        FactoryPolicy[] memory policies = unitFactory.tokenCreationPolicies();
        assertEq(policies.length, 0, "tokenCreationPolicies should be empty by default");

        VaultDataSchema memory schema = unitFactory.vaultDataSchema();
        assertEq(schema.fields.length, 2, "vaultDataSchema field count mismatch");
        assertEq(schema.fields[0].name, "maxReward", "field 0 name mismatch");
        assertEq(schema.fields[0].decimals, 18, "field 0 decimals mismatch");
        assertEq(schema.fields[1].name, "cooldown", "field 1 name mismatch");
        assertEq(schema.fields[1].fieldType, "uint256", "field 1 type mismatch");
        assertTrue(!schema.isArray, "vaultDataSchema should not be array-shaped");

        IVaultFactoryValidationV2.LaunchValidationDataV1 memory nativeData;
        nativeData.quoteToken = address(0);
        (bool nativeOk, string memory nativeReason) = unitFactory.onBeforeLaunch(abi.encode(nativeData));
        assertTrue(nativeOk, "native quote token should pass validation");
        assertEq(nativeReason, "", "native validation reason should be empty");

        IVaultFactoryValidationV2.LaunchValidationDataV1 memory erc20Data;
        erc20Data.quoteToken = address(1);
        (bool erc20Ok, string memory erc20Reason) = unitFactory.onBeforeLaunch(abi.encode(erc20Data));
        assertTrue(!erc20Ok, "non-native quote token should fail validation");
        assertEq(erc20Reason, "FreeCoinVault currently supports native BNB only.", "validation reason mismatch");
    }

    function test_unit_factoryLegacyHookStillReverts() public {
        FreeCoinVaultFactory unitFactory = new FreeCoinVaultFactory();
        IVaultPortalTypes.NewTokenV6WithVaultParams memory params;

        vm.expectRevert(VaultFactoryBaseV2.LegacyV6ValidationHookNotImplemented.selector);
        unitFactory.onBeforeNewTokenV6WithVault(params);
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Receive BNB (needed when calling swapExactInput on DEX for native output)
    // ──────────────────────────────────────────────────────────────────────────

    receive() external payable {}
}

