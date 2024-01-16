// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

interface IERC20 {
    function transfer(address to, uint256 amount) external;
    function balanceOf(address user) external view returns(uint256);
}