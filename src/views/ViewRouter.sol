// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./IPageView.sol";

contract ViewRouter is Ownable {
    mapping(bytes32 => IPageView) public pages;

    event PageRegistered(bytes32 indexed page, address implementation);
    event PageRemoved(bytes32 indexed page);

    constructor() Ownable(msg.sender) {}

    function setPage(bytes32 page, IPageView impl) external onlyOwner {
        pages[page] = impl;
        emit PageRegistered(page, address(impl));
    }

    function removePage(bytes32 page) external onlyOwner {
        delete pages[page];
        emit PageRemoved(page);
    }

    function getNames(bytes32 page) external view returns (string[] memory) {
        IPageView impl = pages[page];
        require(address(impl) != address(0), "Page not registered");
        return impl.getNames();
    }

    function getData(bytes32 page, address user) external view returns (uint256[] memory) {
        IPageView impl = pages[page];
        require(address(impl) != address(0), "Page not registered");
        return impl.getData(user);
    }
}
