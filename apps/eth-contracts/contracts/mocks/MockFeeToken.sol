// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MockFeeToken
 * @dev ERC20 token that charges a fee on transfers, used for testing
 */
contract MockFeeToken is ERC20, Ownable {
    uint256 public feeBasisPoints; // Fee in basis points (1/100 of a percent)
    uint8 private _decimals;

    constructor(
        string memory name,
        string memory symbol,
        uint8 decimals_,
        uint256 _feeBasisPoints
    ) ERC20(name, symbol) Ownable(msg.sender) {
        feeBasisPoints = _feeBasisPoints;
        _decimals = decimals_;
    }

    /**
     * @dev Returns the number of decimals used to get its user representation.
     */
    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    /**
     * @dev Mint tokens to an address (only owner can call)
     * @param to Address to mint tokens to
     * @param amount Amount of tokens to mint
     */
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /**
     * @dev Override transfer function to apply fee
     * @param to Address to transfer tokens to
     * @param amount Amount of tokens to transfer
     * @return success Whether the transfer was successful
     */
    function transfer(address to, uint256 amount) public override returns (bool) {
        uint256 fee = (amount * feeBasisPoints) / 10000;
        uint256 amountAfterFee = amount - fee;

        // Burn the fee
        _burn(_msgSender(), fee);

        // Transfer the remaining amount
        return super.transfer(to, amountAfterFee);
    }

    /**
     * @dev Override transferFrom function to apply fee
     * @param from Address to transfer tokens from
     * @param to Address to transfer tokens to
     * @param amount Amount of tokens to transfer
     * @return success Whether the transfer was successful
     */
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 fee = (amount * feeBasisPoints) / 10000;
        uint256 amountAfterFee = amount - fee;

        // Burn the fee
        _burn(from, fee);

        // Transfer the remaining amount
        return super.transferFrom(from, to, amountAfterFee);
    }
}
