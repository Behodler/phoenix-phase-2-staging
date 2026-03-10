// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IPageView.sol";
import "@phlimbo-ea/interfaces/IPhlimbo.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DepositPageView is IPageView {
    IPhlimbo public immutable phlimbo;
    IERC20 public immutable phUSD;

    constructor(IPhlimbo _phlimbo, IERC20 _phUSD) {
        phlimbo = _phlimbo;
        phUSD = _phUSD;
    }

    function getNames() external pure returns (string[] memory names) {
        names = new string[](7);
        names[0] = "userPhUSDBalance";
        names[1] = "phUSDRewardsPerSecond";
        names[2] = "stableRewardsPerSecond";
        names[3] = "pendingPhUSDRewards";
        names[4] = "pendingStableRewards";
        names[5] = "stakedBalance";
        names[6] = "userAllowance";
    }

    function getData(address user) external view returns (uint256[] memory data) {
        data = new uint256[](7);
        data[0] = phUSD.balanceOf(user);
        data[1] = phlimbo.phUSDPerSecond();
        data[2] = phlimbo.rewardPerSecond();
        data[3] = phlimbo.pendingPhUSD(user);
        data[4] = phlimbo.pendingStable(user);
        (uint256 amount,,) = phlimbo.userInfo(user);
        data[5] = amount;
        data[6] = phUSD.allowance(user, address(phlimbo));
    }
}
