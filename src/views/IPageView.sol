// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IPageView {
    function getNames() external view returns (string[] memory);
    function getData(address user) external view returns (uint256[] memory);
}
