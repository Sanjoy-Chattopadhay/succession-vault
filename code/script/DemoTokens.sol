// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Standard OpenZeppelin tokens deployed on the testnet as the estate in the live demo.
///         Only the deployer can mint.

contract TestUSD is ERC20, Ownable {
    constructor() ERC20("Bequest Test USD", "tUSD") Ownable(msg.sender) {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}

contract HeirloomNFT is ERC721, Ownable {
    constructor() ERC721("Bequest Heirloom", "HEIR") Ownable(msg.sender) {}

    function mint(address to, uint256 id) external onlyOwner {
        _mint(to, id);
    }
}

contract FamilyCollectibles is ERC1155, Ownable {
    constructor() ERC1155("") Ownable(msg.sender) {}

    function mint(address to, uint256 id, uint256 amount) external onlyOwner {
        _mint(to, id, amount, "");
    }
}
