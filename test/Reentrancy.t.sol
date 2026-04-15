// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "../lib/forge-std/src/Test.sol";
import {Vault} from "../src/Vault.sol";
import {VaultFixedCEI} from "../src/VaultFixedCEI.sol";
import {VaultFixedGuard} from "../src/VaultFixedGuard.sol";
import {Attacker} from "../src/Attacker.sol";

contract ReentrancyTest is Test {
    Vault public vault;
    VaultFixedCEI public vaultFixedCEI;
    VaultFixedGuard public vaultFixedGuard;
    Attacker public attacker;
    Attacker public unsuccessfulAttackerFromCEI;
    Attacker public unsuccessfulAttackerFromGuard;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");
    address attackerEOA = makeAddr("attackerEOA");

    function setUp() public {
        vault = new Vault();
        vaultFixedCEI = new VaultFixedCEI();
        vaultFixedGuard = new VaultFixedGuard();

        attacker = new Attacker(address(vault));
        unsuccessfulAttackerFromCEI = new Attacker(address(vaultFixedCEI));
        unsuccessfulAttackerFromGuard = new Attacker(address(vaultFixedGuard));

        vm.deal(alice, 1 ether);
        vm.deal(bob, 1 ether);
        vm.deal(charlie, 1 ether);
        vm.deal(attackerEOA, 1 ether);
    }

    function test_Reentrancy_OriginalVault_Drained() public {
        vm.prank(alice);
        vault.deposit{value: 1 ether}();

        vm.prank(bob);
        vault.deposit{value: 1 ether}();

        vm.prank(charlie);
        vault.deposit{value: 1 ether}();

        attacker.attack{value: 1 ether}();
        assertEq(vault.getBalance(), 0);
        assertEq(address(attacker).balance, 4 ether);
    }

    function test_Reentrancy_CEIFix_Reverts() public {
        vm.prank(alice);
        vaultFixedCEI.deposit{value: 1 ether}();

        vm.prank(bob);
        vaultFixedCEI.deposit{value: 1 ether}();

        vm.prank(charlie);
        vaultFixedCEI.deposit{value: 1 ether}();

        vm.expectRevert();
        unsuccessfulAttackerFromCEI.attack{value: 1 ether}();
    }

    function test_Reentrancy_GuardFix_Reverts() public {
        vm.prank(alice);
        vaultFixedGuard.deposit{value: 1 ether}();

        vm.prank(bob);
        vaultFixedGuard.deposit{value: 1 ether}();

        vm.prank(charlie);
        vaultFixedGuard.deposit{value: 1 ether}();

        vm.expectRevert();
        unsuccessfulAttackerFromGuard.attack{value: 1 ether}();
    }
}