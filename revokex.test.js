const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("RevokeX", function () {
  let owner, user1, user2, spender1, spender2;
  let registry, watchlist;
  let mockToken1, mockToken2;

  beforeEach(async function () {
    [owner, user1, user2, spender1, spender2] = await ethers.getSigners();

    const AllowanceRegistry = await ethers.getContractFactory("AllowanceRegistry");
    registry = await AllowanceRegistry.deploy();
    await registry.waitForDeployment();

    const TokenWatchlist = await ethers.getContractFactory("TokenWatchlist");
    watchlist = await TokenWatchlist.deploy();
    await watchlist.waitForDeployment();

    const MockERC20 = await ethers.getContractFactory("MockERC20");
    mockToken1 = await MockERC20.deploy("Token A", "TKNA", ethers.parseEther("1000000"));
    await mockToken1.waitForDeployment();
    mockToken2 = await MockERC20.deploy("Token B", "TKNB", ethers.parseEther("1000000"));
    await mockToken2.waitForDeployment();

    // Distribute tokens
    await mockToken1.transfer(user1.address, ethers.parseEther("1000"));
    await mockToken1.transfer(user2.address, ethers.parseEther("1000"));
    await mockToken2.transfer(user1.address, ethers.parseEther("500"));
  });

  // ──────────────────────────────────────────────
  // ALLOWANCE LOGGING
  // ──────────────────────────────────────────────
  describe("Logging allowances", function () {
    it("user can log an allowance", async function () {
      await registry.connect(user1).logAllowance(
        await mockToken1.getAddress(), spender1.address, ethers.parseEther("100")
      );
      const ids = await registry.getWalletRecords(user1.address);
      expect(ids.length).to.equal(1);
      const rec = await registry.getRecord(ids[0]);
      expect(rec.token).to.equal(await mockToken1.getAddress());
      expect(rec.spender).to.equal(spender1.address);
      expect(rec.recordedAmount).to.equal(ethers.parseEther("100"));
      expect(rec.revoked).to.be.false;
    });

    it("emits AllowanceLogged event", async function () {
      await expect(
        registry.connect(user1).logAllowance(
          await mockToken1.getAddress(), spender1.address, ethers.MaxUint256
        )
      ).to.emit(registry, "AllowanceLogged");
    });

    it("reverts on zero token address", async function () {
      await expect(
        registry.connect(user1).logAllowance(ethers.ZeroAddress, spender1.address, 100)
      ).to.be.revertedWith("Invalid token");
    });
  });

  // ──────────────────────────────────────────────
  // ALLOWANCE REVOCATION
  // ──────────────────────────────────────────────
  describe("Revoking allowances", function () {
    beforeEach(async function () {
      // user1 approves spender1 on token1
      await mockToken1.connect(user1).approve(spender1.address, ethers.parseEther("500"));
      // Log it
      await registry.connect(user1).logAllowance(
        await mockToken1.getAddress(), spender1.address, ethers.parseEther("500")
      );
    });

    it("user can revoke allowance via registry", async function () {
      await mockToken1.connect(user1).approve(await registry.getAddress(), ethers.parseEther("0"));
      // Direct revoke on token (registry calls approve(spender,0) for user)
      // For test: user calls revokeAllowance on registry, which calls token.approve(spender,0)
      // This requires user to have approved the registry contract beforehand -- but actually
      // revokeAllowance calls token.approve(spender, 0) where msg.sender is user1.
      // This is valid because msg.sender IS user1 when they call revokeAllowance.
      await registry.connect(user1).revokeAllowance(
        await mockToken1.getAddress(), spender1.address
      );

      // Check allowance is now 0
      const allowance = await mockToken1.allowance(user1.address, spender1.address);
      expect(allowance).to.equal(0);
    });

    it("marks record as revoked after revocation", async function () {
      await registry.connect(user1).revokeAllowance(
        await mockToken1.getAddress(), spender1.address
      );
      const ids = await registry.getWalletRecords(user1.address);
      const rec = await registry.getRecord(ids[0]);
      expect(rec.revoked).to.be.true;
      expect(rec.revokedAt).to.be.gt(0);
    });

    it("emits AllowanceRevoked event", async function () {
      await expect(
        registry.connect(user1).revokeAllowance(
          await mockToken1.getAddress(), spender1.address
        )
      ).to.emit(registry, "AllowanceRevoked");
    });
  });

  // ──────────────────────────────────────────────
  // BATCH REVOKE
  // ──────────────────────────────────────────────
  describe("Batch revoke", function () {
    beforeEach(async function () {
      await mockToken1.connect(user1).approve(spender1.address, ethers.parseEther("500"));
      await mockToken2.connect(user1).approve(spender2.address, ethers.parseEther("200"));
    });

    it("batch revokes multiple allowances", async function () {
      await registry.connect(user1).batchRevokeAllowances(
        [await mockToken1.getAddress(), await mockToken2.getAddress()],
        [spender1.address, spender2.address]
      );
      expect(await mockToken1.allowance(user1.address, spender1.address)).to.equal(0);
      expect(await mockToken2.allowance(user1.address, spender2.address)).to.equal(0);
    });

    it("reverts if array length mismatch", async function () {
      await expect(
        registry.connect(user1).batchRevokeAllowances(
          [await mockToken1.getAddress()],
          [spender1.address, spender2.address]
        )
      ).to.be.revertedWith("Length mismatch");
    });

    it("reverts if more than 20 items", async function () {
      const tokens = Array(21).fill(await mockToken1.getAddress());
      const spenders = Array(21).fill(spender1.address);
      await expect(
        registry.connect(user1).batchRevokeAllowances(tokens, spenders)
      ).to.be.revertedWith("Max 20 per batch");
    });
  });

  // ──────────────────────────────────────────────
  // SPENDER REGISTRY (ADMIN)
  // ──────────────────────────────────────────────
  describe("Spender registry", function () {
    it("owner can register a spender", async function () {
      await registry.registerSpender(
        spender1.address, "Uniswap Router", 1, "DEX router", true
      );
      const info = await registry.spenderInfo(spender1.address);
      expect(info.name).to.equal("Uniswap Router");
      expect(info.verified).to.be.true;
    });

    it("non-owner cannot register spender", async function () {
      await expect(
        registry.connect(user1).registerSpender(
          spender1.address, "Hacker", 4, "Bad actor", false
        )
      ).to.be.reverted;
    });

    it("owner can update risk level", async function () {
      await registry.registerSpender(spender1.address, "Some DEX", 1, "DEX", true);
      await registry.updateSpenderRisk(spender1.address, 3); // High
      const info = await registry.spenderInfo(spender1.address);
      expect(info.risk).to.equal(3);
    });
  });

  // ──────────────────────────────────────────────
  // TOKEN WATCHLIST
  // ──────────────────────────────────────────────
  describe("Token watchlist", function () {
    it("user can add token to watchlist", async function () {
      await watchlist.connect(user1).addToWatchlist(await mockToken1.getAddress());
      const list = await watchlist.getUserWatchlist(user1.address);
      expect(list).to.include(await mockToken1.getAddress());
    });

    it("user cannot add same token twice", async function () {
      await watchlist.connect(user1).addToWatchlist(await mockToken1.getAddress());
      await expect(
        watchlist.connect(user1).addToWatchlist(await mockToken1.getAddress())
      ).to.be.revertedWith("Already watching");
    });

    it("user can remove token from watchlist", async function () {
      await watchlist.connect(user1).addToWatchlist(await mockToken1.getAddress());
      await watchlist.connect(user1).removeFromWatchlist(await mockToken1.getAddress());
      const list = await watchlist.getUserWatchlist(user1.address);
      expect(list).to.not.include(await mockToken1.getAddress());
    });

    it("admin can verify a token", async function () {
      await watchlist.connect(owner).verifyToken(await mockToken1.getAddress());
      const info = await watchlist.getTokenInfo(await mockToken1.getAddress());
      expect(info.adminVerified).to.be.true;
      expect(info.symbol).to.equal("TKNA");
    });

    it("non-admin cannot verify token", async function () {
      await expect(
        watchlist.connect(user1).verifyToken(await mockToken1.getAddress())
      ).to.be.reverted;
    });
  });

  // ──────────────────────────────────────────────
  // VIEW FUNCTIONS
  // ──────────────────────────────────────────────
  describe("View functions", function () {
    it("getCurrentAllowance reads live token allowance", async function () {
      await mockToken1.connect(user1).approve(spender1.address, ethers.parseEther("777"));
      const amount = await registry.getCurrentAllowance(
        user1.address, await mockToken1.getAddress(), spender1.address
      );
      expect(amount).to.equal(ethers.parseEther("777"));
    });
  });

  // ──────────────────────────────────────────────
  // PAUSE
  // ──────────────────────────────────────────────
  describe("Pause", function () {
    it("owner can pause and unpause", async function () {
      await registry.pause();
      await expect(
        registry.connect(user1).logAllowance(
          await mockToken1.getAddress(), spender1.address, 100
        )
      ).to.be.reverted;
      await registry.unpause();
      await expect(
        registry.connect(user1).logAllowance(
          await mockToken1.getAddress(), spender1.address, 100
        )
      ).to.not.be.reverted;
    });
  });
});

// ──────────────────────────────────────────────
// MOCK ERC20
// ──────────────────────────────────────────────
// Place MockERC20.sol in contracts/ for tests
