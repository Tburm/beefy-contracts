// SPDX-License-Identifier: MIT

pragma solidity ^0.6.12;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

import "../../interfaces/beefy/IVault.sol";
import "../../interfaces/common/IUniswapRouterETH.sol";
import "../../interfaces/common/IUniswapV2Pair.sol";
import "../../interfaces/common/gauge/IGaugeStaker.sol";
import "../Common/StratManager.sol";
import "../Common/FeeManager.sol";
import "../../utils/GasThrottler.sol";

contract StrategyCommonGauge is StratManager, FeeManager, GasThrottler {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // Tokens used
    address public native;
    address public output;
    address public want;

    // Beefy Contracts
    address public gaugeStaker;

    bool public harvestOnDeposit;
    uint256 public lastHarvest;
    uint256 public wantLocked;
    uint256 private constant WEEK = 7 * 86400;
    uint256 private constant WEEKS_IN_YEAR = 52;

    // Routes
    address[] public outputToNativeRoute;

    event StratHarvest(address indexed harvester, uint256 wantHarvested, uint256 tvl);
    event NotifyRewards(uint256 wantHarvested, uint256 tvl);
    event Deposit(uint256 tvl);
    event Withdraw(uint256 tvl);

    constructor(
        address _want,
        address _gaugeStaker,
        address _vault,
        address _unirouter,
        address _keeper,
        address _strategist,
        address _beefyFeeRecipient,
        address[] memory _outputToNativeRoute
    ) StratManager(_keeper, _strategist, _unirouter, _vault, _beefyFeeRecipient) public {
        want = _want;
        gaugeStaker = _gaugeStaker;

        output = _outputToNativeRoute[0];
        native = _outputToNativeRoute[_outputToNativeRoute.length - 1];
        outputToNativeRoute = _outputToNativeRoute;

        _giveAllowances();
    }

    // puts the funds to work
    function deposit() public whenNotPaused {
        uint256 wantBal = IERC20(want).balanceOf(address(this));

        if (wantBal > 0) {
            emit Deposit(balanceOf());
        }
    }

    function withdraw(uint256 _amount) external {
        require(msg.sender == vault, "!vault");

        uint256 wantBal = IERC20(want).balanceOf(address(this));

        if (wantBal > _amount) {
            wantBal = _amount;
        }

        if (tx.origin != owner() && !paused()) {
            uint256 withdrawalFeeAmount = wantBal.mul(withdrawalFee).div(WITHDRAWAL_MAX);
            wantBal = wantBal.sub(withdrawalFeeAmount);
        }

        IERC20(want).safeTransfer(vault, wantBal);

        emit Withdraw(balanceOf());
    }

    function beforeDeposit() external override {
        if (harvestOnDeposit) {
            require(msg.sender == vault, "!vault");
            _harvest(tx.origin);
        }
    }

    function harvest() external gasThrottle virtual {
        _harvest(tx.origin);
    }

    function harvest(address callFeeRecipient) external gasThrottle virtual {
        _harvest(callFeeRecipient);
    }

    function managerHarvest() external onlyManager {
        _harvest(tx.origin);
    }

    // compounds earnings and charges performance fee
    function _harvest(address callFeeRecipient) internal whenNotPaused {
        uint256 beforeOutputBal = IERC20(output).balanceOf(address(this));
        IGaugeStaker(gaugeStaker).claimVeWantReward();
        uint256 outputBal = IERC20(output).balanceOf(address(this));
        require(outputBal > beforeOutputBal, "!rewards");

        chargeFees(callFeeRecipient);
        uint256 depositBal = depositUnderlying();
        wantLocked = wantLockedLeft().add(depositBal);

        lastHarvest = block.timestamp;
        emit StratHarvest(msg.sender, depositBal, balanceOf());
    }

    // performance fees
    function chargeFees(address callFeeRecipient) internal {
        uint256 toNative = IERC20(output).balanceOf(address(this)).mul(45).div(1000);
        IUniswapRouterETH(unirouter).swapExactTokensForTokens(toNative, 0, outputToNativeRoute, address(this), now);

        uint256 nativeBal = IERC20(native).balanceOf(address(this));

        uint256 callFeeAmount = nativeBal.mul(callFee).div(MAX_FEE);
        IERC20(native).safeTransfer(callFeeRecipient, callFeeAmount);

        uint256 beefyFeeAmount = nativeBal.mul(beefyFee).div(MAX_FEE);
        IERC20(native).safeTransfer(beefyFeeRecipient, beefyFeeAmount);

        uint256 strategistFee = nativeBal.mul(STRATEGIST_FEE).div(MAX_FEE);
        IERC20(native).safeTransfer(strategist, strategistFee);
    }

    // Deposits underlying token to get more want.
    function depositUnderlying() internal returns (uint256) {
        uint256 outputBal = IERC20(output).balanceOf(address(this));
        IVault(want).deposit(outputBal);
        return outputBal;
    }

    // calculate the total underlaying 'want' held by the strat, minus any pending rewards.
    function balanceOf() public view returns (uint256) {
        return balanceOfWant().sub(wantLockedLeft());
    }

    // it calculates how much 'want' this contract holds.
    function balanceOfWant() public view returns (uint256) {
        return IERC20(want).balanceOf(address(this));
    }

    // remaining want rewards not yet distributed on this contract.
    // linear distribution over 1 week.
    function wantLockedLeft() public view returns (uint256) {
        return wantLocked.mul(getMultiplier(block.timestamp, lastHarvest.add(WEEK))).div(WEEK);
    }

    // return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) internal pure returns (uint256) {
        if (_to < _from) {
            return 0;
        }
        return _to.sub(_from);
    }

    // annual percentage rate in 18 decimals.
    function apr() external view returns (uint256) {
        return wantLocked.mul(1e18).div(balanceOf()).mul(WEEKS_IN_YEAR);
    }

    // returns rewards unharvested
    function rewardsAvailable() public returns (uint256) {
        IGaugeStaker(gaugeStaker).claimVeWantReward();
        return IERC20(output).balanceOf(address(this));
    }

    // native reward amount for calling harvest
    function callReward() public returns (uint256) {
        uint256 outputBal = rewardsAvailable();
        uint256 nativeOut;
        if (outputBal > 0) {
            try IUniswapRouterETH(unirouter).getAmountsOut(outputBal, outputToNativeRoute)
                returns (uint256[] memory amountOut) 
            {
                nativeOut = amountOut[amountOut.length -1];
            }
            catch {}
        }

        return nativeOut.mul(45).div(1000).mul(callFee).div(MAX_FEE);
    }

    function setHarvestOnDeposit(bool _harvestOnDeposit) external onlyManager {
        harvestOnDeposit = _harvestOnDeposit;

        if (harvestOnDeposit) {
            setWithdrawalFee(0);
        } else {
            setWithdrawalFee(10);
        }
    }

    function setShouldGasThrottle(bool _shouldGasThrottle) external onlyManager {
        shouldGasThrottle = _shouldGasThrottle;
    }

    // notify the contract of any rewards outside of fee distribution.
    // extend the lock for another week.
    function notifyRewards(bool _chargeFees) external onlyManager {
        if (_chargeFees) {
            chargeFees(tx.origin);
        }
        uint256 depositBal = depositUnderlying();
        wantLocked = wantLockedLeft().add(depositBal);
        lastHarvest = block.timestamp;
        emit NotifyRewards(depositBal, balanceOf());
    }

    // called as part of strat migration. Sends all the available funds back to the vault.
    function retireStrat() external {
        require(msg.sender == vault, "!vault");

        uint256 wantBal = IERC20(want).balanceOf(address(this));
        IERC20(want).transfer(vault, wantBal);
    }

    // pauses deposits and withdraws all funds from third party systems.
    function panic() public onlyManager {
        pause();
    }

    function pause() public onlyManager {
        _pause();

        _removeAllowances();
    }

    function unpause() external onlyManager {
        _unpause();

        _giveAllowances();

        deposit();
    }

    function _giveAllowances() internal {
        IERC20(output).safeApprove(unirouter, uint256(-1));
        IERC20(output).safeApprove(want, uint256(-1));
    }

    function _removeAllowances() internal {
        IERC20(output).safeApprove(unirouter, 0);
        IERC20(output).safeApprove(want, 0);
    }

    function outputToNative() external view returns (address[] memory) {
        return outputToNativeRoute;
    }
}
