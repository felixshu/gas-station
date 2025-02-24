// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract MockERC20 is ERC20Permit {
    uint8 private _decimals;

    constructor(
        string memory _name,
        string memory _symbol,
        uint8 _decimalsValue
    ) ERC20(_name, _symbol) ERC20Permit(_name) {
        _decimals = _decimalsValue;
    }
    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
