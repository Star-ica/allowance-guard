# AllowanceGuard — Deployment Guide

## Prerequisites
- Node.js >= 18, npm >= 9, funded deployer wallet

## 1. Setup
```bash
mkdir allowanceguard-deploy && cd allowanceguard-deploy
npm init -y
npm install --save-dev hardhat @nomicfoundation/hardhat-toolbox
npm install @openzeppelin/contracts dotenv
npx hardhat init
```

## 2. `.env`
```env
PRIVATE_KEY=0xyour_key
BOT_RPC_URL=https://rpc.botchain.tg
EXPLORER_API_KEY=your_key
```

## 3. `hardhat.config.js`
```js
require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();
module.exports = {
  solidity: { version: "0.8.20", settings: { optimizer: { enabled: true, runs: 200 } } },
  networks: { botchain: { url: process.env.BOT_RPC_URL, chainId: 677, accounts: [process.env.PRIVATE_KEY] } },
  etherscan: {
    apiKey: { botchain: process.env.EXPLORER_API_KEY || "none" },
    customChains: [{ network: "botchain", chainId: 677,
      urls: { apiURL: "https://explorer.botchain.tg/api", browserURL: "https://explorer.botchain.tg" } }]
  }
};
```

## 4. MockERC20.sol (for tests only)
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol, uint256 supply) ERC20(name, symbol) {
        _mint(msg.sender, supply);
    }
}
```

## 5. Deploy Script (`scripts/deploy.js`)
```js
const { ethers } = require("hardhat");
const fs = require("fs");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);

  const AllowanceRegistry = await ethers.getContractFactory("AllowanceRegistry");
  const registry = await AllowanceRegistry.deploy();
  await registry.waitForDeployment();
  console.log("AllowanceRegistry:", await registry.getAddress());

  const TokenWatchlist = await ethers.getContractFactory("TokenWatchlist");
  const watchlist = await TokenWatchlist.deploy();
  await watchlist.waitForDeployment();
  console.log("TokenWatchlist:", await watchlist.getAddress());

  const addrs = {
    AllowanceRegistry: await registry.getAddress(),
    TokenWatchlist: await watchlist.getAddress()
  };
  fs.writeFileSync("deployed-addresses.json", JSON.stringify(addrs, null, 2));
  console.log("Addresses saved to deployed-addresses.json");
}

main().catch(e => { console.error(e); process.exit(1); });
```

```bash
npx hardhat compile
npx hardhat run scripts/deploy.js --network botchain
```

## 6. Seed Known Spenders (optional)
```js
// scripts/seed-spenders.js
const { ethers } = require("hardhat");
const addrs = require("./deployed-addresses.json");
const ABI = ["function registerSpender(address,string,uint8,string,bool) external"];

async function main() {
  const [deployer] = await ethers.getSigners();
  const registry = new ethers.Contract(addrs.AllowanceRegistry, ABI, deployer);

  const spenders = [
    { addr: "0xYourDEXRouter", name: "BOT DEX Router", risk: 1, desc: "Official DEX", verified: true },
    // add more
  ];

  for (const s of spenders) {
    await (await registry.registerSpender(s.addr, s.name, s.risk, s.desc, s.verified)).wait();
    console.log("Registered:", s.name);
  }
}
main().catch(console.error);
```

## 7. Verify
```bash
npx hardhat verify --network botchain <ALLOWANCE_REGISTRY>
npx hardhat verify --network botchain <TOKEN_WATCHLIST>
```

## 8. Frontend Config
In `index.html`, update `CONFIG.contracts` with deployed addresses and set `DEMO = false`.

## 9. Post-Deploy Checklist
- [ ] Both contracts verified on explorer
- [ ] Seed known spenders via seed-spenders.js
- [ ] Admin verifies popular tokens on TokenWatchlist
- [ ] Test: logAllowance, revokeAllowance, batchRevokeAllowances
- [ ] Test: addToWatchlist, removeFromWatchlist
- [ ] Test pause/unpause
- [ ] Connect frontend to deployed contracts
- [ ] Confirm approve(spender,0) succeeds for test token
