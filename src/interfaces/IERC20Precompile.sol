// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Polkadot Hub native asset ERC-20 precompile interface
// Address formula: 0x[assetId 8hex][24 zeros][01200000]
// USDT (Asset ID 1984 = 0x7C0): checksum = 0x000007c000000000000000000000000001200000
// NOTE: name(), symbol(), decimals() are NOT exposed — hardcode or read via Substrate RPC
address constant USDT_PRECOMPILE = 0x000007c000000000000000000000000001200000;

interface IERC20Precompile {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}
