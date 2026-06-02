// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";

import {FreeCoinVaultUpgradeable, FreeCoinVaultBeaconFactory} from "src/FreeCoinBeacon.sol";
import {VaultUISchema, VaultDataSchema, FactoryPolicy} from "src/flap/IVaultSchemasV1.sol";
import {VaultFactoryBaseV2} from "src/flap/VaultFactoryBaseV2.sol";
import {IVaultPortalTypes} from "src/flap/IVaultPortal.sol";
import {IVaultFactoryValidationV2} from "src/flap/IVaultFactory.sol";

contract RejectingClaimer {
    receive() external payable {
        revert("reject-claim");
    }

    function claim(address vault) external {
        FreeCoinVaultUpgradeable(payable(vault)).claim();
    }
}

contract FreeCoinBeaconTest is Test {
    uint256 internal constant TESTNET_CHAIN_ID = 97;
    address internal constant TESTNET_VAULT_PORTAL = 0x027e3704fC5C16522e9393d04C60A3ac5c0d775f;
    address internal constant TESTNET_GUARDIAN = 0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950;

    address internal constant TAX_TOKEN = address(0xBEEF);
    address internal constant USER = address(0xCAFE);
    address internal constant USER2 = address(0xCAFF);
    address internal constant FORWARD_TO = address(0xF0AA);

    uint256 internal constant MAX_REWARD = 0.25 ether;
    uint256 internal constant COOLDOWN = 30 minutes;

    FreeCoinVaultBeaconFactory internal factory;
    FreeCoinVaultUpgradeable internal vault;
    RejectingClaimer internal rejectingClaimer;

    function setUp() public {
        vm.chainId(TESTNET_CHAIN_ID);

        factory = new FreeCoinVaultBeaconFactory();
        rejectingClaimer = new RejectingClaimer();

        vm.prank(TESTNET_VAULT_PORTAL);
        address vaultAddr = factory.newVault(TAX_TOKEN, address(0), address(this), abi.encode(MAX_REWARD, COOLDOWN));
        vault = FreeCoinVaultUpgradeable(payable(vaultAddr));
    }

    function test_beaconFactoryDeploysInitializedProxyVault() public view {
        assertTrue(factory.beaconImplementation() != address(0), "beacon implementation should be set");
        assertEq(vault.taxToken(), TAX_TOKEN, "taxToken mismatch");
        assertEq(vault.maxReward(), MAX_REWARD, "maxReward mismatch");
        assertEq(vault.cooldown(), COOLDOWN, "cooldown mismatch");
        assertEq(vault.getNextClaimTime(), 0, "next claim time should start at zero");
    }

    function test_descriptionBeforeAndAfterClaim() public {
        assertEq(
            vault.description(),
            unicode"FreeCoinVault: No claims yet. Call claim() to receive free BNB! / 还没有人领取，调用 claim() 领取免费 BNB！",
            "initial description mismatch"
        );

        vm.deal(address(vault), MAX_REWARD);
        vm.prank(USER);
        vault.claim();

        assertEq(
            vault.description(),
            unicode"FreeCoinVault: Free BNB for everyone! Call claim() to receive your reward. / 人人有份的免费 BNB！调用 claim() 领取奖励。",
            "post-claim description mismatch"
        );
    }

    function test_claimWithZeroBalanceStillUpdatesState() public {
        vm.prank(USER);
        vault.claim();

        assertTrue(vault.hasClaimed(USER), "zero-balance claim should still mark address claimed");
        assertEq(vault.lastClaimer(), USER, "lastClaimer mismatch");
        assertEq(vault.lastReward(), 0, "lastReward should be zero");
        assertEq(vault.getNextClaimTime(), block.timestamp + COOLDOWN, "next claim time mismatch");
    }

    function test_beaconProxyClaimAndInitializerLock() public {
        vm.deal(address(vault), 1 ether);
        vm.deal(USER, 1 ether);

        uint256 userBalanceBefore = USER.balance;

        vm.prank(USER);
        vault.claim();

        uint256 reward = USER.balance - userBalanceBefore;
        assertEq(reward, MAX_REWARD, "claim reward should be capped by maxReward");
        assertTrue(vault.hasClaimed(USER), "user should be marked as claimed");
        assertEq(vault.lastClaimer(), USER, "lastClaimer mismatch");
        assertEq(vault.lastReward(), MAX_REWARD, "lastReward mismatch");
        assertEq(vault.getNextClaimTime(), block.timestamp + COOLDOWN, "cooldown should advance after claim");

        vm.expectRevert("Initializable: contract is already initialized");
        vault.initialize(address(0x1234), 1, 1);

        address implementation = factory.beaconImplementation();
        vm.expectRevert("Initializable: contract is already initialized");
        FreeCoinVaultUpgradeable(payable(implementation)).initialize(address(0x1234), 1, 1);
    }

    function test_claimCooldownAndDoubleClaimReverts() public {
        vm.deal(address(vault), 1 ether);

        vm.prank(USER);
        vault.claim();

        vm.expectRevert(bytes(unicode"Already claimed / 已经领取过"));
        vm.prank(USER);
        vault.claim();

        vm.expectRevert(bytes(unicode"Cooldown not elapsed / 冷却时间未结束"));
        vm.prank(USER2);
        vault.claim();
    }

    function test_claimRevertsWhenRecipientRejectsNativeTransfer() public {
        vm.deal(address(vault), MAX_REWARD);

        vm.expectRevert(bytes(unicode"Transfer failed / 转账失败"));
        rejectingClaimer.claim(address(vault));

        assertTrue(!vault.hasClaimed(address(rejectingClaimer)), "failed claim should roll back claimed flag");
        assertEq(vault.lastClaimer(), address(0), "failed claim should not persist lastClaimer");
        assertEq(vault.lastReward(), 0, "failed claim should not persist lastReward");
    }

    function test_getterHelpersAndCappedReward() public {
        (address initialClaimer, uint256 initialReward) = vault.getLastClaimerAndReward();
        assertEq(initialClaimer, address(0), "initial claimer should be zero");
        assertEq(initialReward, 0, "initial reward should be zero");

        vm.deal(address(vault), MAX_REWARD / 2);
        assertEq(vault.getNextReward(), MAX_REWARD / 2, "reward should equal balance below cap");

        vm.deal(address(vault), MAX_REWARD * 2);
        assertEq(vault.getNextReward(), MAX_REWARD, "reward should be capped at maxReward");
        assertEq(vault.getNextClaimTime(), 0, "nextClaimTime should start at zero");
    }

    function test_receiveAccumulatesFundsInVault() public {
        uint256 vaultBalanceBefore = address(vault).balance;
        vm.deal(USER, 1 ether);
        vm.prank(USER);
        (bool ok,) = address(vault).call{value: 0.4 ether}("");
        assertTrue(ok, "transfer should succeed");
        assertEq(address(vault).balance, vaultBalanceBefore + 0.4 ether, "vault should retain received BNB");
    }

    function test_emergencyWithdrawHooksAreUnavailableOnBeaconVault() public {
        (bool nativeOk,) = address(vault).call(abi.encodeWithSignature("emergencyWithdrawNative(address)", FORWARD_TO));
        assertTrue(!nativeOk, "beacon vault should not expose emergencyWithdrawNative");

        (bool tokenOk,) = address(vault)
            .call(abi.encodeWithSignature("emergencyWithdrawToken(address,address)", TAX_TOKEN, FORWARD_TO));
        assertTrue(!tokenOk, "beacon vault should not expose emergencyWithdrawToken");
    }

    function test_vaultUISchemaMetadata() public view {
        VaultUISchema memory schema = vault.vaultUISchema();

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

    function test_factoryRejectsNonVaultPortalCaller() public {
        vm.expectRevert(bytes(unicode"Only VaultPortal / 仅限 VaultPortal 调用"));
        factory.newVault(TAX_TOKEN, address(0), address(this), abi.encode(MAX_REWARD, COOLDOWN));
    }

    function test_guardianCanUpgradeBeaconImplementation() public {
        FreeCoinVaultUpgradeable nextImplementation = new FreeCoinVaultUpgradeable();

        vm.prank(TESTNET_GUARDIAN);
        factory.upgradeVaultImplementation(address(nextImplementation));

        assertEq(
            factory.beaconImplementation(),
            address(nextImplementation),
            "guardian upgrade should change beacon implementation"
        );
    }

    function test_nonGuardianCannotUpgradeBeaconImplementation() public {
        FreeCoinVaultUpgradeable nextImplementation = new FreeCoinVaultUpgradeable();

        vm.expectRevert(bytes(unicode"Only Guardian / 仅限 Guardian"));
        vm.prank(USER);
        factory.upgradeVaultImplementation(address(nextImplementation));
    }

    function test_factoryMetadataAndValidationHelpers() public view {
        assertTrue(factory.isQuoteTokenSupported(address(0)), "native quote token should be supported");
        assertTrue(!factory.isQuoteTokenSupported(address(1)), "ERC20 quote token should be rejected");
        assertEq(factory.factorySpecVersion(), "v2.2", "factory spec version mismatch");

        FactoryPolicy[] memory policies = factory.tokenCreationPolicies();
        assertEq(policies.length, 0, "tokenCreationPolicies should be empty by default");

        VaultDataSchema memory schema = factory.vaultDataSchema();
        assertEq(schema.fields.length, 2, "vaultDataSchema field count mismatch");
        assertEq(schema.fields[0].name, "maxReward", "field 0 name mismatch");
        assertEq(schema.fields[0].decimals, 18, "field 0 decimals mismatch");
        assertEq(schema.fields[1].name, "cooldown", "field 1 name mismatch");
        assertEq(schema.fields[1].fieldType, "uint256", "field 1 type mismatch");
        assertTrue(!schema.isArray, "vaultDataSchema should not be array-shaped");

        IVaultFactoryValidationV2.LaunchValidationDataV1 memory nativeData;
        nativeData.quoteToken = address(0);
        (bool nativeOk, string memory nativeReason) = factory.onBeforeLaunch(abi.encode(nativeData));
        assertTrue(nativeOk, "native quote token should pass validation");
        assertEq(nativeReason, "", "native validation reason should be empty");

        IVaultFactoryValidationV2.LaunchValidationDataV1 memory erc20Data;
        erc20Data.quoteToken = address(1);
        (bool erc20Ok, string memory erc20Reason) = factory.onBeforeLaunch(abi.encode(erc20Data));
        assertTrue(!erc20Ok, "non-native quote token should fail validation");
        assertEq(erc20Reason, "FreeCoinVault currently supports native BNB only.", "validation reason mismatch");
    }

    function test_factoryLegacyHookStillReverts() public {
        IVaultPortalTypes.NewTokenV6WithVaultParams memory params;

        vm.expectRevert(VaultFactoryBaseV2.LegacyV6ValidationHookNotImplemented.selector);
        factory.onBeforeNewTokenV6WithVault(params);
    }
}

