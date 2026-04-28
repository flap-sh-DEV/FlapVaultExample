// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {VaultBase} from "./flap/VaultBase.sol";
import {VaultBaseV2} from "./flap/VaultBaseV2.sol";
import {VaultFactoryBaseV2} from "./flap/VaultFactoryBaseV2.sol";
import {IVaultFactory} from "./flap/IVaultFactory.sol";
import {
    VaultUISchema,
    VaultMethodSchema,
    VaultDataSchema,
    FieldDescriptor,
    ApproveAction
} from "./flap/IVaultSchemasV1.sol";

/// @title FreeCoinVault
/// @notice A vault that distributes free BNB rewards to anyone who calls `claim()`.
/// @dev
///   - All tax revenue flows into this vault via `receive()`.
///   - The vault creator sets a `maxReward` (per-claim cap) and a `cooldown`
///     (seconds between consecutive claims, global — not per-user).
///   - Anyone can call `claim()` once. The payout is
///     `min(address(this).balance, maxReward)`.
///   - After a successful claim the vault enters a cooldown period during
///     which no one can claim.
contract FreeCoinVault is VaultBaseV2 {
    // ──────────────────────────── State ───────────────────────────────────
    address public taxToken;

    uint256 public maxReward;
    uint256 public cooldown;

    uint256 public nextClaimTime;
    address public lastClaimer;
    uint256 public lastReward;

    mapping(address => bool) public hasClaimed;

    // ──────────────────────────── Constructor ────────────────────────────
    constructor(address _taxToken, uint256 _maxReward, uint256 _cooldown) {
        taxToken = _taxToken;
        maxReward = _maxReward;
        cooldown = _cooldown;
    }

    // ──────────────────────────── Receive BNB ────────────────────────────
    receive() external payable {}

    // ──────────────────────────── Write ──────────────────────────────────

    /// @notice Claim free BNB from the vault.
    /// @dev
    ///   - Each address may only claim once (reverts with `AlreadyClaimed`).
    ///   - Must wait until `nextClaimTime` (reverts with `CooldownNotElapsed`).
    ///   - Payout = min(balance, maxReward).
    function claim() external {
        require(!hasClaimed[msg.sender], unicode"Already claimed / 已经领取过");
        require(block.timestamp >= nextClaimTime, unicode"Cooldown not elapsed / 冷却时间未结束");

        hasClaimed[msg.sender] = true;
        nextClaimTime = block.timestamp + cooldown;

        uint256 balance = address(this).balance;
        uint256 reward = balance < maxReward ? balance : maxReward;

        lastClaimer = msg.sender;
        lastReward = reward;

        if (reward > 0) {
            (bool ok,) = msg.sender.call{value: reward}("");
            require(ok, unicode"Transfer failed / 转账失败");
        }
    }

    // ──────────────────────────── View helpers ───────────────────────────

    /// @notice Returns the reward the next claimer would receive right now.
    /// @return reward  min(balance, maxReward)
    function getNextReward() external view returns (uint256 reward) {
        uint256 balance = address(this).balance;
        reward = balance < maxReward ? balance : maxReward;
    }

    /// @notice Returns the timestamp when the next claim becomes possible.
    /// @return timestamp  The earliest `block.timestamp` at which `claim()` will succeed.
    function getNextClaimTime() external view returns (uint256 timestamp) {
        timestamp = nextClaimTime;
    }

    /// @notice Returns the last successful claimer and the amount they received.
    /// @return claimer  Address of the last claimer (address(0) if none yet).
    /// @return reward   Amount of BNB the last claimer received.
    function getLastClaimerAndReward() external view returns (address claimer, uint256 reward) {
        claimer = lastClaimer;
        reward = lastReward;
    }

    // ──────────────────────────── VaultBase overrides ────────────────────

    /// @inheritdoc VaultBase
    function description() public view override returns (string memory) {
        if (lastClaimer == address(0)) {
            return
                unicode"FreeCoinVault: No claims yet. Call claim() to receive free BNB! / 还没有人领取，调用 claim() 领取免费 BNB！";
        }
        return
        unicode"FreeCoinVault: Free BNB for everyone! Call claim() to receive your reward. / 人人有份的免费 BNB！调用 claim() 领取奖励。";
    }

    // ──────────────────────────── VaultBaseV2 override ───────────────────

    /// @inheritdoc VaultBaseV2
    function vaultUISchema() public pure override returns (VaultUISchema memory schema) {
        schema.vaultType = "FreeCoinVault";
        schema.description = unicode"A vault that gives away free BNB to anyone who calls claim(). "
            unicode"Each address can only claim once, and there is a cooldown between claims. / "
            unicode"任何人调用 claim() 即可领取免费 BNB，每个地址仅限一次，两次领取之间有冷却时间。";

        schema.methods = new VaultMethodSchema[](4);

        // ── View: getNextReward() ────────────────────────────────────────
        schema.methods[0].name = "getNextReward";
        schema.methods[0].description = unicode"Returns the reward the next claimer would receive. / 返回下一位领取者将获得的奖励。";
        schema.methods[0].inputs = new FieldDescriptor[](0);
        schema.methods[0].outputs = new FieldDescriptor[](1);
        schema.methods[0].outputs[0] = FieldDescriptor("reward", "uint256", "Next reward amount in BNB", 18);
        schema.methods[0].approvals = new ApproveAction[](0);

        // ── View: getNextClaimTime() ─────────────────────────────────────
        schema.methods[1].name = "getNextClaimTime";
        schema.methods[1].description = unicode"Returns the timestamp when the next claim can be made. / 返回下次可领取的时间戳。";
        schema.methods[1].inputs = new FieldDescriptor[](0);
        schema.methods[1].outputs = new FieldDescriptor[](1);
        schema.methods[1].outputs[0] = FieldDescriptor("timestamp", "time", "Next claim timestamp (unix)", 0);
        schema.methods[1].approvals = new ApproveAction[](0);

        // ── View: getLastClaimerAndReward() ──────────────────────────────
        schema.methods[2].name = "getLastClaimerAndReward";
        schema.methods[2].description =
            unicode"Returns the address of the last claimer and the reward they received. / 返回上一位领取者的地址及其获得的奖励。";
        schema.methods[2].inputs = new FieldDescriptor[](0);
        schema.methods[2].outputs = new FieldDescriptor[](2);
        schema.methods[2].outputs[0] = FieldDescriptor("claimer", "address", "Last claimer address", 0);
        schema.methods[2].outputs[1] = FieldDescriptor("reward", "uint256", "Reward received by last claimer", 18);
        schema.methods[2].approvals = new ApproveAction[](0);

        // ── Write: claim() ───────────────────────────────────────────────
        schema.methods[3].name = "claim";
        schema.methods[3].description = unicode"Claim free BNB. Each address can only claim once. "
            unicode"There is a global cooldown between claims. / " unicode"领取免费 BNB，每个地址仅限一次，两次领取之间有全局冷却时间。";
        schema.methods[3].inputs = new FieldDescriptor[](0);
        schema.methods[3].outputs = new FieldDescriptor[](0);
        schema.methods[3].approvals = new ApproveAction[](0);
        schema.methods[3].isWriteMethod = true;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Factory
// ─────────────────────────────────────────────────────────────────────────────

/// @title FreeCoinVaultFactory
/// @notice Factory that creates `FreeCoinVault` instances.
/// @dev    `vaultData` is ABI-encoded as `(uint256 maxReward, uint256 cooldown)`.
contract FreeCoinVaultFactory is VaultFactoryBaseV2 {
    // ──────────────────────────── IVaultFactory ──────────────────────────

    /// @inheritdoc IVaultFactory
    function newVault(address taxToken, address, /* quoteToken */ address, /* creator */ bytes calldata vaultData)
        external
        override
        returns (address vault)
    {
        address vaultPortal = _getVaultPortal();
        require(msg.sender == vaultPortal, unicode"Only VaultPortal / 仅限 VaultPortal 调用");

        (uint256 maxReward, uint256 cooldown) = abi.decode(vaultData, (uint256, uint256));

        FreeCoinVault v = new FreeCoinVault(taxToken, maxReward, cooldown);
        vault = address(v);
    }

    /// @inheritdoc IVaultFactory
    function isQuoteTokenSupported(address) external pure override returns (bool) {
        return true;
    }

    // ──────────────────────────── VaultFactoryBaseV2 override ────────────

    /// @inheritdoc VaultFactoryBaseV2
    function vaultDataSchema() public pure override returns (VaultDataSchema memory schema) {
        schema.description = unicode"Creates a FreeCoinVault that gives free BNB to callers of claim(). "
            unicode"Each address claims once; payout is capped at maxReward or balance. "
            unicode"A cooldown separates consecutive claims. / " unicode"创建 FreeCoinVault，任何人调用 claim() 即可领取免费 BNB。"
            unicode"每个地址仅限一次，奖励上限为 maxReward 或余额（取较小值），两次领取之间有冷却期。";
        schema.fields = new FieldDescriptor[](2);
        schema.fields[0] = FieldDescriptor("maxReward", "uint256", "Maximum BNB reward per claim", 18);
        schema.fields[1] = FieldDescriptor("cooldown", "uint256", "Cooldown period between claims in seconds", 0);
        schema.isArray = false;
    }
}
