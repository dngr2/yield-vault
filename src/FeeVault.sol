// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title FeeVault
/// @notice An ERC-4626 tokenized vault that charges a bounded, time-based management fee on AUM
///         and a bounded performance fee on yield earned above a per-share high-water mark.
///         Fees are realized by minting vault shares to `feeRecipient` (dilution), never by
///         pulling raw assets out of the vault, so the owner can never seize user principal.
/// @dev Built on OpenZeppelin's audited ERC4626. Inflation / first-depositor donation attacks are
///      mitigated by the built-in virtual-shares defense: `_decimalsOffset()` returns a nonzero
///      value so a lone attacker cannot round a victim's minted shares down to zero by donating
///      assets into an (almost) empty vault.
///
///      v2 adds three LP-safety guards, all of which leave the withdrawal path untouched so users
///      can ALWAYS exit:
///        * a bounded deposit cap (honored via `maxDeposit`/`maxMint`),
///        * a deposit-only pause switch,
///        * a rate-limit on fee INCREASES (bounded step + cooldown) so LPs are never surprised by a
///          sudden hike and always have time to leave. Fee decreases remain instant.
contract FeeVault is ERC4626, Ownable {
    using Math for uint256;

    // --- Constants -----------------------------------------------------------

    /// @dev Basis-point denominator (100% == 10_000 bps).
    uint256 public constant BPS = 10_000;

    /// @dev Seconds in a (non-leap) year, used for the annualized management fee.
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    /// @dev Hard cap on the annual management fee (5%).
    uint16 public constant MAX_MGMT_FEE_BPS = 500;

    /// @dev Hard cap on the performance fee (20%).
    uint16 public constant MAX_PERF_FEE_BPS = 2_000;

    /// @dev Largest single upward step allowed for either fee (1%). Decreases are unrestricted.
    uint16 public constant MAX_FEE_INCREASE_STEP_BPS = 100;

    /// @dev Minimum delay between two consecutive increases of the same fee.
    uint256 public constant FEE_INCREASE_COOLDOWN = 7 days;

    /// @dev Fixed-point precision for the per-share price used by the high-water mark.
    uint256 private constant PPS_PRECISION = 1e18;

    /// @dev Virtual-shares decimals offset. Nonzero => inflation-attack resistant.
    uint8 private constant DECIMALS_OFFSET = 6;

    /// @dev Cached `10 ** DECIMALS_OFFSET`. Constant, so the fee-share math avoids a runtime
    ///      `_decimalsOffset()` call + EXP on every accrual.
    uint256 private constant VIRTUAL_SHARES = 10 ** DECIMALS_OFFSET;

    // --- Storage -------------------------------------------------------------

    /// @notice Annual management fee, in basis points of AUM.
    uint16 public mgmtFeeBps;

    /// @notice Performance fee, in basis points of profit above the high-water mark.
    uint16 public perfFeeBps;

    /// @notice When true, new deposits/mints are blocked. Withdrawals/redemptions are never blocked.
    bool public depositsPaused;

    /// @notice Recipient of all minted fee shares.
    address public feeRecipient;

    /// @notice Timestamp of the last fee accrual.
    uint64 public lastAccrualTime;

    /// @notice Timestamp of the last upward management-fee change (for the cooldown guard).
    uint64 public lastMgmtIncreaseTime;

    /// @notice Timestamp of the last upward performance-fee change (for the cooldown guard).
    uint64 public lastPerfIncreaseTime;

    /// @notice Highest gross per-share price (scaled by PPS_PRECISION) ever charged against.
    ///         Performance fees only apply to price above this mark. Zero means "uninitialized".
    uint256 public highWaterMark;

    /// @notice Maximum total assets (AUM) the vault will accept. Zero means "no cap".
    uint256 public depositCap;

    // --- Events --------------------------------------------------------------

    /// @notice Emitted whenever fees are accrued and shares minted to `feeRecipient`.
    /// @param feeShares Total shares minted this accrual (management + performance).
    /// @param feeAssets Asset-denominated value of those shares at accrual time.
    /// @param newHighWaterMark The high-water mark after this accrual.
    event FeesAccrued(uint256 feeShares, uint256 feeAssets, uint256 newHighWaterMark);

    event MgmtFeeUpdated(uint16 oldBps, uint16 newBps);
    event PerfFeeUpdated(uint16 oldBps, uint16 newBps);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event DepositCapUpdated(uint256 oldCap, uint256 newCap);
    event DepositsPausedSet(bool paused);

    // --- Errors --------------------------------------------------------------

    error FeeTooHigh(uint16 provided, uint16 max);
    error ZeroAddress();
    error FeeIncreaseTooLarge(uint16 step, uint16 maxStep);
    error FeeIncreaseTooSoon(uint256 nextAllowed);

    // --- Constructor ---------------------------------------------------------

    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        uint16 mgmtFeeBps_,
        uint16 perfFeeBps_,
        address feeRecipient_,
        address owner_
    ) ERC20(name_, symbol_) ERC4626(asset_) Ownable(owner_) {
        if (mgmtFeeBps_ > MAX_MGMT_FEE_BPS) revert FeeTooHigh(mgmtFeeBps_, MAX_MGMT_FEE_BPS);
        if (perfFeeBps_ > MAX_PERF_FEE_BPS) revert FeeTooHigh(perfFeeBps_, MAX_PERF_FEE_BPS);
        if (feeRecipient_ == address(0)) revert ZeroAddress();

        mgmtFeeBps = mgmtFeeBps_;
        perfFeeBps = perfFeeBps_;
        feeRecipient = feeRecipient_;
        lastAccrualTime = uint64(block.timestamp);

        // Seed the high-water mark at the fresh-vault per-share price. The first deposit mints
        // `assets * 10^offset` shares, so gross pps = assets*1e18 / (assets*10^offset) = 1e18/10^offset,
        // independent of the deposit size or the asset's own decimals. Seeding it here (rather than
        // lazily on the first funded accrual) ensures the very first unit of yield is treated as
        // profit rather than being absorbed into the baseline.
        highWaterMark = PPS_PRECISION / VIRTUAL_SHARES;
    }

    // --- Inflation-attack defense -------------------------------------------

    /// @dev Virtual shares/assets offset. A nonzero offset makes the first-depositor donation
    ///      ("inflation") attack economically unviable: the attacker must donate ~1e(OFFSET) times
    ///      the value they hope to steal, and even then rounding favors the vault, not the attacker.
    function _decimalsOffset() internal pure override returns (uint8) {
        return DECIMALS_OFFSET;
    }

    // --- Fee accrual ---------------------------------------------------------

    /// @notice Public entry point to accrue fees (e.g. after external yield lands in the vault).
    ///         Any deposit/mint/withdraw/redeem also accrues first, so this is only needed to
    ///         checkpoint fees without otherwise interacting.
    function harvest() external {
        _accrueFees();
    }

    /// @dev Checkpoint fees since the last accrual and mint the corresponding shares to the
    ///      fee recipient. Called at the start of every user interaction (before pricing) so that
    ///      previews and execution observe the same post-fee state.
    ///
    ///      Management fee: `AUM * mgmtFeeBps/BPS * elapsed/SECONDS_PER_YEAR` (linear in time).
    ///      Performance fee: `perfFeeBps/BPS` of profit, where profit is the increase of the gross
    ///      per-share price above the high-water mark, times supply. The high-water mark only
    ///      ratchets up, so a loss-then-recovery pays NO performance fee until the prior peak price
    ///      is exceeded again — profit is never double-charged.
    function _accrueFees() internal {
        uint256 nowTs = block.timestamp;
        uint256 supply = totalSupply();

        // Nothing to charge against an empty vault; just move the time checkpoint forward.
        if (supply == 0) {
            lastAccrualTime = uint64(nowTs);
            return;
        }

        uint256 assets = totalAssets();
        uint256 elapsed = nowTs - lastAccrualTime;
        uint256 currentPPS = assets.mulDiv(PPS_PRECISION, supply);
        uint256 hwm = highWaterMark;
        bool newHigh = currentPPS > hwm;

        uint256 feeAssets;

        // Management fee: linear on AUM over elapsed time.
        uint16 mgmtBps = mgmtFeeBps; // single SLOAD
        if (mgmtBps != 0 && elapsed != 0) {
            feeAssets += assets.mulDiv(uint256(mgmtBps) * elapsed, BPS * SECONDS_PER_YEAR);
        }

        // Performance fee: only on gross per-share price above the high-water mark.
        uint16 perfBps = perfFeeBps; // single SLOAD
        if (perfBps != 0 && newHigh) {
            uint256 profitAssets = (currentPPS - hwm).mulDiv(supply, PPS_PRECISION);
            feeAssets += profitAssets.mulDiv(perfBps, BPS);
        }

        // Ratchet the high-water mark up to the current gross peak. Only write when it actually
        // moves (the common no-new-high path skips the SSTORE entirely).
        if (newHigh) {
            hwm = currentPPS;
            highWaterMark = currentPPS;
        }
        // Only bump the time checkpoint when time has actually passed; skips a redundant SSTORE
        // for same-block re-accruals.
        if (elapsed != 0) {
            lastAccrualTime = uint64(nowTs);
        }

        if (feeAssets == 0) return;

        // Safety clamp: never try to mint against more than the vault holds.
        if (feeAssets >= assets) {
            feeAssets = assets - 1;
        }

        // Shares that, once minted, grant `feeRecipient` a claim worth exactly `feeAssets`:
        //   s = feeAssets * (supply + 10^offset) / (assets - feeAssets + 1)
        // This mirrors ERC4626's virtual-share conversion but nets out the assets being claimed,
        // so existing holders are diluted by precisely the fee's value and no more.
        uint256 feeShares = feeAssets.mulDiv(supply + VIRTUAL_SHARES, assets - feeAssets + 1, Math.Rounding.Floor);

        if (feeShares == 0) return;

        _mint(feeRecipient, feeShares);
        emit FeesAccrued(feeShares, feeAssets, hwm);
    }

    // --- ERC4626 overrides (accrue before every interaction) -----------------

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        _accrueFees();
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override returns (uint256) {
        _accrueFees();
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
        _accrueFees();
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256) {
        _accrueFees();
        return super.redeem(shares, receiver, owner);
    }

    // --- Deposit limits (cap + pause) ----------------------------------------

    /// @notice Maximum assets that can currently be deposited. Returns 0 while deposits are paused,
    ///         and otherwise the remaining room under `depositCap` (unbounded when the cap is 0).
    function maxDeposit(address) public view override returns (uint256) {
        if (depositsPaused) return 0;
        uint256 cap = depositCap;
        if (cap == 0) return type(uint256).max;
        uint256 assets = totalAssets();
        return assets >= cap ? 0 : cap - assets;
    }

    /// @notice Maximum shares that can currently be minted, mirroring {maxDeposit}'s cap/pause logic.
    function maxMint(address receiver) public view override returns (uint256) {
        uint256 room = maxDeposit(receiver);
        if (room == type(uint256).max || room == 0) return room;
        return previewDeposit(room);
    }

    // --- Owner controls (bounded) --------------------------------------------

    /// @notice Update the management fee. Accrues pending fees at the old rate first. Increases are
    ///         rate-limited (bounded step + cooldown); decreases are always allowed.
    function setMgmtFeeBps(uint16 newBps) external onlyOwner {
        if (newBps > MAX_MGMT_FEE_BPS) revert FeeTooHigh(newBps, MAX_MGMT_FEE_BPS);
        uint16 oldBps = mgmtFeeBps;
        if (newBps > oldBps) {
            _guardFeeIncrease(oldBps, newBps, lastMgmtIncreaseTime);
            lastMgmtIncreaseTime = uint64(block.timestamp);
        }
        _accrueFees();
        emit MgmtFeeUpdated(oldBps, newBps);
        mgmtFeeBps = newBps;
    }

    /// @notice Update the performance fee. Accrues pending fees at the old rate first. Increases are
    ///         rate-limited (bounded step + cooldown); decreases are always allowed.
    function setPerfFeeBps(uint16 newBps) external onlyOwner {
        if (newBps > MAX_PERF_FEE_BPS) revert FeeTooHigh(newBps, MAX_PERF_FEE_BPS);
        uint16 oldBps = perfFeeBps;
        if (newBps > oldBps) {
            _guardFeeIncrease(oldBps, newBps, lastPerfIncreaseTime);
            lastPerfIncreaseTime = uint64(block.timestamp);
        }
        _accrueFees();
        emit PerfFeeUpdated(oldBps, newBps);
        perfFeeBps = newBps;
    }

    /// @dev Enforce the LP-safety rate-limit on an upward fee change: the step may not exceed
    ///      `MAX_FEE_INCREASE_STEP_BPS`, and at least `FEE_INCREASE_COOLDOWN` must have elapsed
    ///      since the previous increase of the same fee.
    function _guardFeeIncrease(uint16 oldBps, uint16 newBps, uint64 lastIncreaseTime) private view {
        uint16 step = newBps - oldBps;
        if (step > MAX_FEE_INCREASE_STEP_BPS) revert FeeIncreaseTooLarge(step, MAX_FEE_INCREASE_STEP_BPS);
        uint256 nextAllowed = uint256(lastIncreaseTime) + FEE_INCREASE_COOLDOWN;
        if (lastIncreaseTime != 0 && block.timestamp < nextAllowed) revert FeeIncreaseTooSoon(nextAllowed);
    }

    /// @notice Update the fee recipient. Accrues pending fees to the old recipient first.
    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();
        _accrueFees();
        emit FeeRecipientUpdated(feeRecipient, newRecipient);
        feeRecipient = newRecipient;
    }

    /// @notice Set the AUM deposit cap (0 == uncapped). Lowering below current AUM simply stops new
    ///         deposits; it never forces or blocks existing holders from withdrawing.
    function setDepositCap(uint256 newCap) external onlyOwner {
        emit DepositCapUpdated(depositCap, newCap);
        depositCap = newCap;
    }

    /// @notice Pause or unpause deposits/mints. Withdrawals and redemptions are never affected, so
    ///         users can always exit.
    function setDepositsPaused(bool paused) external onlyOwner {
        depositsPaused = paused;
        emit DepositsPausedSet(paused);
    }

    // --- Views ---------------------------------------------------------------

    /// @notice Current gross per-share price, scaled by 1e18 (0 if no shares outstanding).
    function pricePerShare() external view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        return totalAssets().mulDiv(PPS_PRECISION, supply);
    }
}
