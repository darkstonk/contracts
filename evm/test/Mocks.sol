// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// A plain 18-decimal coin for local runs, standing in for a Pons launch.
contract MockCoin {
    string public name = "Mock Pons";
    string public symbol = "MOCK";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(address to) {
        totalSupply = 1e27;
        balanceOf[to] = 1e27;
        emit Transfer(address(0), to, 1e27);
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        emit Approval(msg.sender, s, a);
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        emit Transfer(msg.sender, to, a);
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
        emit Transfer(f, to, a);
        return true;
    }
}

/// Answers getLaunchedToken like a Pons factory that launched every coin asked about.
contract MockPonsFactory {
    function getLaunchedToken(address t) external pure returns (address) {
        return t;
    }
}
