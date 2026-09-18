// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface Vm {
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function warp(uint256) external;
    function expectRevert() external;
    function expectRevert(bytes4) external;
    function expectPartialRevert(bytes4) external;
}

abstract contract TestBase {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function assertTrue(bool value) internal pure {
        require(value, "assertTrue failed");
    }

    function assertEq(uint256 a, uint256 b) internal pure {
        require(a == b, "assertEq(uint256) failed");
    }

    function assertEq(int256 a, int256 b) internal pure {
        require(a == b, "assertEq(int256) failed");
    }

    function assertApproxEqAbs(uint256 a, uint256 b, uint256 tolerance) internal pure {
        uint256 difference = a > b ? a - b : b - a;
        require(difference <= tolerance, "assertApproxEqAbs failed");
    }
}
