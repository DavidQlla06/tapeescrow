// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MockReleaseCircuit — test double for the TapeOut release circuit
/// @notice Implements the EXACT same boolean logic as circuit/release_logic.v:
///     RELEASE = done AND (approved OR timeoutPassed) AND (NOT disputed)
/// In production this role is played by the real TapeOut processor contract
/// (see README.md "Production integration"). The circuitId parameter is
/// accepted and ignored here; a production adapter uses it to select the
/// tape-out circuit on the processor.
contract MockReleaseCircuit {
    function evaluate(
        uint256 /* circuitId */,
        bool done,
        bool approved,
        bool timeoutPassed,
        bool disputed
    ) external pure returns (bool) {
        return done && (approved || timeoutPassed) && !disputed;
    }
}

/// @title MockUSDC — minimal ERC20 stand-in for tests
/// @notice Only the functions TapeEscrow uses. 6 decimals like real USDC.
contract MockUSDC {
    string public name = "Mock USDC";
    string public symbol = "mUSDC";
    uint8 public decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient balance");
        require(allowance[from][msg.sender] >= amount, "insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}
