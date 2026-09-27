// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {EnvKey} from "./EnvKey.sol";

/// @notice Tokens for the public web demo: anyone can mint, so visitors can put something in a
///         vault without asking the deployer. Test networks only; they have no value.
contract DemoCollectible is ERC721 {
    uint256 public nextId = 1;

    constructor() ERC721("Demo Collectible", "DCOL") {}

    /// Mint the next collectible to the caller.
    function mint() external returns (uint256 id) {
        id = nextId++;
        _mint(msg.sender, id);
    }
}

contract DemoDollar is ERC20 {
    uint256 public constant FAUCET_AMOUNT = 1_000e6;

    constructor() ERC20("Demo Dollar", "DUSD") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// 1,000 DUSD to the caller.
    function faucet() external {
        _mint(msg.sender, FAUCET_AMOUNT);
    }
}

/// forge script script/DemoPublicTokens.s.sol --rpc-url sepolia --broadcast
contract DeployDemoPublicTokens is EnvKey {
    function run() external {
        uint256 pk = _envKey();
        if (pk != 0) vm.startBroadcast(pk);
        else vm.startBroadcast();
        DemoCollectible nft = new DemoCollectible();
        DemoDollar usd = new DemoDollar();
        vm.stopBroadcast();
        console.log("DEMO_COLLECTIBLE", address(nft));
        console.log("DEMO_DOLLAR", address(usd));
    }
}
