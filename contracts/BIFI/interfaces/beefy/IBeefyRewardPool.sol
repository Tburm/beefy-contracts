// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;

interface IBeefyRewardPool {
    function stake(uint256) external;
    function withdraw(uint256) external;
    function getReward() external;
    function earned(address _user) external view returns (uint256);
    function balanceOf(address _user) external view returns (uint256);
    function notifyRewardAmount(uint256 _amount) external;
    function inCaseTokensGetStuck(address _token) external;
    function transferOwnership(address _owner) external;
}
